import Foundation
import Virtualization

/// `cryo bay freeze` and `cryo bay thaw-test`: the VM driver end to end (docs/spec/capsule.md).
/// Freeze makes a capsule's saved state; thaw-test runs the refill + lease path against it.
enum Freeze {
	struct Options {
		var args: [String]
		func value(_ name: String) -> String? {
			guard let i = args.firstIndex(of: name), i + 1 < args.count else { return nil }
			return args[i + 1]
		}
		func flag(_ name: String) -> Bool { args.contains(name) }
		func int(_ name: String) throws -> Int? {
			guard let v = value(name) else { return nil }
			guard let n = Int(v) else { throw BayError("\(name) must be a number, got '\(v)'") }
			return n
		}
	}

	/// The image a capsule belongs to: `--image <digest>` or the config's.
	static func resolveImage(_ o: Options, paths: BayPaths) throws -> (digest: String, files: ImageFiles) {
		let configured = try BayConfig.load(paths.config).image
		guard let digest = o.value("--image") ?? configured else {
			throw BayError("no image: pass --image <digest> or set image in \(paths.config.path)")
		}
		let files = paths.image(digest)
		for f in [files.base, files.hardwareModel, files.auxTemplate, files.info, files.guestKey] where !FileManager.default.fileExists(atPath: f.path) {
			throw BayError("image \(digest) is missing \(f.lastPathComponent)")
		}
		return (digest, files)
	}

	// MARK: freeze

	/// Seconds a freeze waits after boot (and warm-up) so login items finish before the snapshot.
	static let settleS = 45
	/// Freezes tried before giving up on one whose first SSH after resume stalls.
	static let verifyTries = 4

	@MainActor
	static func freeze(_ args: [String], paths: BayPaths, out: BayCommand.Writer) async throws -> Int32 {
		let o = Options(args: args)
		guard let n = try o.int("--capsule"), let subnet = try o.int("--subnet") else {
			throw BayError(
				"usage: cryo bay freeze --capsule N --subnet S [--settle \(settleS)] [--warm-up [ios,macos]] [--image <digest>] [--no-verify] [--verify-tries \(verifyTries)]"
			)
		}
		guard (0...255).contains(subnet) else { throw BayError("--subnet must be 0...255 (10.77.S.0/24)") }
		let settle = Double(try o.int("--settle") ?? settleS)
		// `--warm-up` alone means iOS; a following value that isn't a flag lists the platforms.
		let warmUp: [String]? =
			o.flag("--warm-up")
			? try WarmUp.platforms(o.value("--warm-up").flatMap { $0.hasPrefix("--") ? nil : $0 }) : nil
		let (digest, image) = try resolveImage(o, paths: paths)
		let info = try BayJSON.read(ImageInfo.self, from: image.info)
		// A running bay holds this capsule's files and VMs (Apple allows 2 per Mac).
		try Cleanup.refuseWhileBayRuns(paths)
		try paths.prepare()
		try Cleanup.registerVMProcess(paths)
		// A freeze or refreeze that crashed half way: put swapped-out capsules back, drop staging.
		Cleanup.repairRefreezes(paths)
		let capsule = paths.capsule(n)
		// Frozen into staging and swapped in only once it worked, so a failure keeps the old capsule.
		let staged = staging("freeze", n, paths: paths)

		let tries = o.flag("--no-verify") ? 1 : try o.int("--verify-tries") ?? verifyTries
		do {
			return try await CapsuleVM.session {
				_ = try await freezeVerified(
					paths: paths, image: image, digest: digest, info: info, capsule: staged, subnet: subnet, settle: settle,
					warmUp: warmUp, tries: tries, out: out)
				try swapIn([(staged.dir, capsule)], paths: paths)
				return 0
			}
		} catch {
			try? FileManager.default.removeItem(at: staged.dir)
			throw error
		}
	}

	/// `capsules/.tmp-<kind>-N.<pid>`: where this process freezes capsule N before the swap.
	/// Start-up cleanup deletes it once the process is gone (Leftovers.refreezeRepairs).
	static func staging(_ kind: String, _ n: Int, paths: BayPaths) -> CapsuleFiles {
		CapsuleFiles(dir: paths.capsules.appending(path: Leftovers.staging(kind, n), directoryHint: .isDirectory), number: n)
	}

	/// Moves staged capsules in place of the live ones: every live capsule aside to
	/// `capsules/.tmp-old-N` first, then every staged one in, then the old ones go. A failure puts
	/// everything back as it was; a crash between the renames is repaired at the next start-up.
	static func swapIn(_ capsules: [(staged: URL, live: CapsuleFiles)], paths: BayPaths) throws {
		let fm = FileManager.default
		func old(_ live: CapsuleFiles) -> URL { paths.capsules.appending(path: ".tmp-old-\(live.number)", directoryHint: .isDirectory) }
		var movedOut: [CapsuleFiles] = []
		var movedIn: [(staged: URL, live: CapsuleFiles)] = []
		do {
			for c in capsules where fm.fileExists(atPath: c.live.dir.path) {
				try? fm.removeItem(at: old(c.live))
				try fm.moveItem(at: c.live.dir, to: old(c.live))
				movedOut.append(c.live)
			}
			for c in capsules {
				try fm.moveItem(at: c.staged, to: c.live.dir)
				movedIn.append(c)
			}
		} catch {
			for c in movedIn.reversed() { try? fm.moveItem(at: c.live.dir, to: c.staged) }
			for live in movedOut.reversed() { try? fm.moveItem(at: old(live), to: live.dir) }
			throw error
		}
		for live in movedOut { try? fm.removeItem(at: old(live)) }
	}

	/// Freeze, then (with `tries` > 1) thaw once to check the first SSH after resume. Some freezes
	/// stall the guest's network for ~2.7 s after every resume, cause unknown, so a slow
	/// one is frozen again.
	@MainActor
	static func freezeVerified(
		paths: BayPaths, image: ImageFiles, digest: String, info: ImageInfo, capsule: CapsuleFiles, subnet: Int, settle: Double,
		warmUp: [String]?, identity: CapsuleFiles? = nil, tries: Int, out: BayCommand.Writer
	) async throws -> CapsuleManifest {
		let limit = Double(ProcessInfo.processInfo.environment["CRYO_VERIFY_MS"] ?? "1000") ?? 1000
		for attempt in 1...max(tries, 1) {
			let manifest = try await freezeOnce(
				paths: paths, image: image, digest: digest, info: info, capsule: capsule, subnet: subnet, settle: settle,
				warmUp: warmUp, identity: identity, out: out)
			guard tries > 1 else { return manifest }
			let ssh = try await verify(paths: paths, image: image, digest: digest, capsule: capsule, manifest: manifest)
			if ssh <= limit {
				out("verify: first SSH \(Int(ssh)) ms after resume, ok\n")
				return manifest
			}
			out("verify: first SSH \(Int(ssh)) ms after resume (> \(Int(limit)) ms, network stall), refreezing (\(attempt)/\(tries))\n")
		}
		throw BayError("capsule \(capsule.number): every freeze stalled after resume (\(tries) tries)")
	}

	/// The bay's background refreeze after a cold boot fallback: freezes into
	/// `capsules/.tmp-refreeze-N.<pid>` with the capsule's own identity (MAC, machine ID, aux),
	/// its subnet and its warm-up, then swaps the new capsule in. On failure the old one stays as it
	/// was. The new freeze has the device set new freezes get (no vsock), and its manifest says so.
	@MainActor
	static func refreeze(
		paths: BayPaths, image: ImageFiles, digest: String, info: ImageInfo, capsule: CapsuleFiles, manifest: CapsuleManifest,
		out: BayCommand.Writer
	) async throws -> CapsuleManifest {
		let fresh = staging("refreeze", capsule.number, paths: paths)
		defer { try? FileManager.default.removeItem(at: fresh.dir) }
		let warmUp = RefreezePlan.warmUp(recorded: manifest.warmUp, imageTag: info.tag)
		let m = try await freezeVerified(
			paths: paths, image: image, digest: digest, info: info, capsule: fresh, subnet: manifest.network.subnet,
			settle: Double(settleS), warmUp: warmUp, identity: capsule, tries: verifyTries, out: out)
		try swapIn([(fresh.dir, capsule)], paths: paths)
		return m
	}

	/// Cold boot on a new thin layer, settle, save, write the manifest. The identity (machine ID,
	/// MAC, aux) is new, or copied from `identity` when it has one (a refreeze keeps its capsule's).
	@MainActor
	static func freezeOnce(
		paths: BayPaths, image: ImageFiles, digest: String, info: ImageInfo, capsule: CapsuleFiles, subnet: Int, settle: Double,
		warmUp: [String]? = nil, identity: CapsuleFiles? = nil, out: BayCommand.Writer
	) async throws -> CapsuleManifest {
		let fm = FileManager.default
		try? fm.removeItem(at: capsule.dir)
		try fm.createDirectory(at: capsule.dir, withIntermediateDirectories: true)
		let mac: String
		if let id = identity, let m = try? String(contentsOf: id.mac, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines),
			VZMACAddress(string: m) != nil, fm.fileExists(atPath: id.machineID.path), fm.fileExists(atPath: id.aux.path)
		{
			mac = m
			try fm.copyItem(at: id.machineID, to: capsule.machineID)
			try fm.copyItem(at: id.aux, to: capsule.aux)  // APFS clone
		} else {
			try VZMacMachineIdentifier().dataRepresentation.write(to: capsule.machineID)
			mac = VZMACAddress.randomLocallyAdministered().string
			try fm.copyItem(at: image.auxTemplate, to: capsule.aux)  // APFS clone of the golden aux
		}
		try mac.write(to: capsule.mac, atomically: true, encoding: .utf8)

		let network = CapsuleNetwork(subnet: subnet)
		// The VM and the manifest get the same device set (a saved state only restores onto it). No
		// vsock device on new freezes: readiness, clock and rekey all go over SSH. Capsules frozen
		// with one still restore with it, since VMSpec follows their manifest.
		let vsock = false
		let inputs = true
		let spec = VMSpec(
			hardwareModel: image.hardwareModel, machineID: capsule.machineID, mac: mac, aux: capsule.aux, cpus: info.cpus,
			memoryGB: info.memoryGB, subnet: subnet, vsock: vsock, inputs: inputs, emptyShare: paths.emptyShare)
		let guest = Guest(ip: network.guestIP, key: image.guestKey)

		let cold: Double
		let frozenMS: Double
		let cvm = try CapsuleVM.make(spec, disk: try CapsuleVM.freezeDisk(image: image, capsule: capsule))
		do {
			out("freezing capsule \(capsule.number): \(info.cpus) vCPU, \(info.memoryGB) GB, vmnet \(network.gateway)/24, guest \(network.guestIP)\n")
			let t0 = uptimeNS()
			try await cvm.start()
			// The image boots on DHCP, which may not give .2: find the guest by its MAC, then
			// pin .2 statically. A capsule frozen before already has .2 pinned in its layer.
			var first = guest
			try await waitFor("SSH port", timeout: 600, every: 0.1) {
				first = Guest(ip: DHCPLeases.guestIP(mac: mac, subnet: subnet), key: image.guestKey)
				if await first.probe() { return true }
				return first.ip != guest.ip ? await guest.probe() : false
			}
			if await guest.probe() { first = guest }
			let tPort = uptimeNS()
			try await waitFor("SSH login", timeout: 120, every: 0.2) { await first.ssh("true").status == 0 }
			cold = elapsedMS(t0, uptimeNS())
			out("cold boot: port 22 \(Int(elapsedMS(t0, tPort))) ms, ssh \(Int(cold)) ms\(first.ip == guest.ip ? "" : " (DHCP gave \(first.ip))")\n")
			// On another address the session drops when the address changes, so only .2's login counts.
			// networksetup right after a cold boot once took over 10 s (configd still busy).
			let pin = await first.ssh(network.staticIPCommand, timeout: 90)
			guard pin.status == 0 || first.ip != guest.ip else { throw BayError("static IP \(network.guestIP): \(pin.out)") }
			try await waitFor("SSH login on the static IP", timeout: 30, every: 0.2) { await guest.ssh("true").status == 0 }

			if let warmUp {
				out("warm-up build (\(warmUp.joined(separator: ", ")))...\n")
				try await WarmUp.run(guest, platforms: warmUp, out: out)
			}
			out("settling \(Int(settle))s so login items finish before the snapshot...\n")
			try await Task.sleep(for: .seconds(settle))
			// No `purge`: it barely shrank the state and made the first SSH after a thaw ~1 s instead of ~120 ms.
			await guest.ssh("sync")
			// A few logins so sshd/PAM/opendirectoryd pages are warm in the snapshot.
			for _ in 0..<3 { await guest.ssh("true") }

			let t1 = uptimeNS()
			try await cvm.pause()
			try await cvm.save(to: capsule.state)
			frozenMS = elapsedMS(t1, uptimeNS())
			try await cvm.stop()
		} catch {
			// The bay's background refreeze has no session to stop it: don't leave it running.
			if cvm.state != .stopped && cvm.state != .error { try? await cvm.stop() }
			throw error
		}
		let size = (try? fm.attributesOfItem(atPath: capsule.state.path)[.size] as? Int) ?? 0
		out("frozen in \(Int(frozenMS)) ms, state file \(size >> 20) MB\n")

		let manifest = CapsuleManifest(
			image: digest, cpus: info.cpus, memoryGB: info.memoryGB, mac: mac, network: network, vsock: vsock, inputs: inputs,
			host: Host.fingerprint(), files: CapsuleManifest.stamps(image: image, capsule: capsule), frozenAt: Date(),
			coldBootMS: Int(cold), warmUp: warmUp ?? [])
		try BayJSON.write(manifest, to: capsule.manifest)
		return manifest
	}

	/// Thaw a just-frozen capsule once and return resume to first successful SSH, in ms.
	@MainActor
	static func verify(
		paths: BayPaths, image: ImageFiles, digest: String, capsule: CapsuleFiles, manifest: CapsuleManifest
	) async throws -> Double {
		let t = try await CapsuleVM.thaw(
			paths: paths, image: image, digest: digest, capsule: capsule, manifest: manifest, leaseID: "verify-\(capsule.number)")
		// Every way out stops the VM and removes `leases/verify-N` (the bay's refreeze has no session).
		do {
			guard !t.coldBooted else { throw BayError("verify restore failed: \(t.fallbackReason ?? "?")") }
			let guest = Guest(ip: manifest.network.guestIP, key: image.guestKey)
			try await Task.sleep(for: .seconds(1))
			let t0 = uptimeNS()
			try await t.cvm.resume()
			try await waitFor("SSH after verify thaw", timeout: 60, every: 0.05) { await guest.ssh("true").status == 0 }
			let elapsed = elapsedMS(t0, uptimeNS())
			await CapsuleVM.release(t)
			return elapsed
		} catch {
			await CapsuleVM.release(t)
			throw error
		}
	}

	// MARK: thaw-test

	/// Restore, resume, readiness login, rekey, warm-up, pause (refill); then resume as a lease.
	@MainActor
	static func thawTest(_ args: [String], paths: BayPaths, out: BayCommand.Writer) async throws -> Int32 {
		let o = Options(args: args)
		guard let n = try o.int("--capsule") else { throw BayError("usage: cryo bay thaw-test --capsule N [--runs 3] [--image <digest>]") }
		let runs = max(try o.int("--runs") ?? 3, 1)
		let (digest, image) = try resolveImage(o, paths: paths)
		try Cleanup.registerVMProcess(paths)
		let capsule = paths.capsule(n)
		let manifest: CapsuleManifest
		do { manifest = try BayJSON.read(CapsuleManifest.self, from: capsule.manifest) } catch {
			throw BayError("capsule \(n): can't read \(capsule.manifest.path): \(error)")
		}
		let guest = Guest(ip: manifest.network.guestIP, key: image.guestKey)
		let mismatch = manifest.mismatches(image: image, capsule: capsule, digest: digest)
		if mismatch.isEmpty {
			out("capsule \(n): manifest ok, guest \(guest.ip)\n")
		} else {
			out("capsule \(n): manifest mismatch, cold boot fallback:\n" + mismatch.map { "  \($0)\n" }.joined())
		}

		return try await CapsuleVM.session {
			out("   run  restore  resume+ssh  rekey  pause | lease: resume   port    ssh  total | host key\n")
			var keys: Set<String> = []
			var frozenKey = ""
			var leases: [Double] = []
			for r in 1...runs {
				let id = "tt\(r)-\(Int(Date().timeIntervalSince1970) % 100000)"
				// Refill (shared with the bay): bring it up, rekey, warm up, pause.
				let refilled = try await Refill.run(
					paths: paths, image: image, digest: digest, capsule: capsule, manifest: manifest, guest: guest, leaseID: id,
					installKey: false,
					beforeRekey: { if frozenKey.isEmpty { frozenKey = await guest.hostKey() } })
				let t = refilled.thawed
				if let why = t.fallbackReason { out("  FALLBACK cold boot: \(why)\n") }
				let up = Activation(resume: refilled.upMS)
				try await Task.sleep(for: .seconds(2))

				// Lease: resume as a client would.
				let lease = try await activate(t.cvm, guest: guest, resume: true)
				let key = await guest.hostKey()
				let name = await guest.ssh("scutil --get HostName").out.trimmingCharacters(in: .whitespacesAndNewlines)
				keys.insert(key)
				leases.append(lease.total)
				out(
					String(
						format: "%6d %8.0f %11.0f %6.0f %6.0f | %13.0f %6.0f %6.0f %6.0f | %@ %@\n",
						r, t.restoreMS, up.total, refilled.rekeyMS, refilled.pauseMS, lease.resume, lease.port, lease.ssh, lease.total,
						String(key.suffix(16)), name == "cryo-\(id)" ? "hostname ok" : "HOSTNAME \(name)"))
				await CapsuleVM.release(t)
			}
			out("distinct host keys: \(keys.count) of \(runs); frozen key reused: \(keys.contains(frozenKey) ? "YES" : "no")\n")
			if !leases.isEmpty { out("lease median \(Int(median(leases))) ms\n") }
			return keys.count == runs && !keys.contains(frozenKey) ? 0 : 1
		}
	}

	struct Activation {
		var resume = 0.0, port = 0.0, ssh = 0.0
		var total: Double { resume + port + ssh }
	}

	/// Resume (unless cold booted) and wait until a login works. The readiness login also sets the
	/// guest clock, which is still at freeze time.
	@MainActor
	static func activate(_ cvm: CapsuleVM, guest: Guest, resume: Bool) async throws -> Activation {
		let t2 = uptimeNS()
		if resume { try await cvm.resume() }
		let t3 = uptimeNS()
		try await waitFor("SSH port after thaw", timeout: 120, every: 0.02) { await guest.probe() }
		let t4 = uptimeNS()
		try await waitFor("SSH login after thaw", timeout: 120, every: 0.05) { await guest.ssh(Guest.clockCommand()).status == 0 }
		return Activation(resume: elapsedMS(t2, t3), port: elapsedMS(t3, t4), ssh: elapsedMS(t4, uptimeNS()))
	}

	static func median(_ xs: [Double]) -> Double {
		let s = xs.sorted()
		guard !s.isEmpty else { return 0 }
		return s.count % 2 == 1 ? s[s.count / 2] : (s[s.count / 2 - 1] + s[s.count / 2]) / 2
	}
}

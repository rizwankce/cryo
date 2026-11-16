import CryoAPI
import Foundation

/// `cryo bay lease-test [--folder DIR] [--cache NAME] [--runs 2] [--queue]`: the bay end to end in
/// this process, no HTTP server. Leases with the per-lease key (not the image key), checks the
/// inputs, releases with the cache saved, leases again and checks the cache survived.
enum LeaseTest {
	@MainActor
	static func run(_ args: [String], paths: BayPaths, out: BayCommand.Writer) async throws -> Int32 {
		let o = Freeze.Options(args: args)
		let folder = o.value("--folder")
		let cache = o.value("--cache")
		let runs = try o.int("--runs") ?? 2
		var failures = 0
		func check(_ ok: Bool, _ what: String) {
			out("  \(ok ? "ok  " : "FAIL") \(what)\n")
			if !ok { failures += 1 }
		}

		return try await CapsuleVM.session {
			// `out` can't be captured (non-escaping), and this is a terminal tool.
			BayTrace.sink = { FileHandle.standardOutput.write(Data("    [\($0)]\n".utf8)) }
			let bay = Bay(paths: paths)
			let t0 = uptimeNS()
			try await bay.start()
			out("bay started, \(await bay.status().capsules.count) capsule(s) thawed in \(Int(elapsedMS(t0, uptimeNS()))) ms\n")

			let keyDir = FileManager.default.temporaryDirectory.appending(path: "cryo-lease-test-\(getpid())", directoryHint: .isDirectory)
			try FileManager.default.createDirectory(at: keyDir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
			defer { try? FileManager.default.removeItem(at: keyDir) }

			for r in 1...max(runs, 1) {
				out("run \(r)\n")
				let a = uptimeNS()
				let lease = try await bay.createLease(LeaseRequest(folder: folder, cache: cache, waitS: 60, name: "lease-test"), viaNetwork: false)
				out(String(format: "  lease %@ on capsule %d in %.0f ms\n", lease.id, lease.capsule, elapsedMS(a, uptimeNS())))

				let keyFile = keyDir.appending(path: lease.id)
				try lease.ssh.key.write(to: keyFile, atomically: true, encoding: .utf8)
				try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: keyFile.path)
				let target = try await bay.connectTarget(lease.id)
				let guest = Guest(ip: target.host, key: keyFile)

				let name = await guest.ssh("scutil --get HostName").out.trimmingCharacters(in: .whitespacesAndNewlines)
				check(name == lease.ssh.host, "hostname \(name) == \(lease.ssh.host) (login with the per-lease key)")
				check(lease.ssh.config == LeaseInputs.sshConfig(id: lease.id), "ssh config shape")
				let scanned = await guest.hostKey()
				check(!scanned.isEmpty && lease.ssh.hostKey == "ssh-ed25519 \(scanned)", "lease pins the guest's host key")
				if let folder {
					let local = ((try? FileManager.default.contentsOfDirectory(atPath: folder)) ?? []).filter { !$0.hasPrefix(".") }.sorted()
					let remote = await guest.ssh("ls -1 \(LeaseInputs.shellQuote(LeaseInputs.shareMount))").out
						.split(separator: "\n").map(String.init).sorted()
					check(local == remote, "folder visible at \(LeaseInputs.shareMount): \(remote.count) entries")
					let w = await guest.ssh("cd \(LeaseInputs.shellQuote(LeaseInputs.shareMount)) && echo x > written-by-guest.txt")
					check(w.status == 0, "guest can write in the folder")
					check(
						!FileManager.default.fileExists(atPath: URL(filePath: folder).appending(path: "written-by-guest.txt").path),
						"original folder untouched (clone)")
				}
				if cache != nil {
					let mount = LeaseInputs.cacheMount
					for earlier in 1..<r {
						let seen = await guest.ssh("cat \(mount)/marker-\(earlier)").out.trimmingCharacters(in: .whitespacesAndNewlines)
						check(seen == "run-\(earlier)", "cache marker from run \(earlier) survived")
					}
					let w = await guest.ssh("echo run-\(r) > \(mount)/marker-\(r) && sync && cat \(mount)/marker-\(r)")
					check(w.out.contains("run-\(r)"), "cache writable at \(mount)")
				}

				let b = uptimeNS()
				try await bay.release(lease.id, saveCache: true)
				let releaseMS = elapsedMS(b, uptimeNS())
				let c = uptimeNS()
				try await waitFor("capsules to refill", timeout: 120, every: 0.1) { await bay.status().capsules.allSatisfy { $0.state == "thawed" } }
				out(String(format: "  released in %.0f ms, refilled in %.0f ms\n", releaseMS, elapsedMS(c, uptimeNS())))
				do {
					_ = try await bay.lease(lease.id)
					check(false, "released lease is gone")
				} catch {
					check((error as? ServiceError)?.code == APIError.notFound, "released lease -> not_found")
				}
			}

			if o.flag("--queue") { failures += try await queue(bay, out: out) }
			await bay.shutdown()
			BayTrace.sink = nil
			out(failures == 0 ? "lease-test passed\n" : "lease-test: \(failures) check(s) failed\n")
			return failures == 0 ? 0 : 1
		}
	}

	/// Every capsule leased, a third request with `wait_s` 5 fails after ~5 s, then a long wait is
	/// served by the capsule a release frees.
	@MainActor
	static func queue(_ bay: Bay, out: BayCommand.Writer) async throws -> Int {
		var failures = 0
		out("queue\n")
		let n = await bay.status().capsules.count
		var held: [Lease] = []
		for _ in 0..<n { held.append(try await bay.createLease(LeaseRequest(waitS: 0), viaNetwork: false)) }
		let a = uptimeNS()
		do {
			_ = try await bay.createLease(LeaseRequest(waitS: 5), viaNetwork: false)
			out("  FAIL third lease should not have been served\n")
			failures += 1
		} catch {
			let ms = Int(elapsedMS(a, uptimeNS()))
			let ok = (error as? ServiceError)?.code == APIError.noCapacity && (4500...6500).contains(ms)
			out("  \(ok ? "ok  " : "FAIL") third request -> \(error) after \(ms) ms\n")
			if !ok { failures += 1 }
		}
		let q = await bay.status().queue
		out("  \(q == 0 ? "ok  " : "FAIL") queue empty after the timeout (\(q))\n")
		if q != 0 { failures += 1 }

		// A client that hangs up leaves the queue.
		let hangup = Task { @MainActor in try await bay.createLease(LeaseRequest(waitS: 120), viaNetwork: false) }
		try await Task.sleep(for: .seconds(1))
		let queued = await bay.status().queue
		hangup.cancel()
		let cancelled: Bool
		do {
			_ = try await hangup.value
			cancelled = false
		} catch { cancelled = error is CancellationError }
		let after = await bay.status().queue
		let okCancel = queued == 1 && cancelled && after == 0
		out("  \(okCancel ? "ok  " : "FAIL") cancelled waiter left the queue (queued \(queued), after \(after))\n")
		if !okCancel { failures += 1 }

		async let waiting = bay.createLease(LeaseRequest(waitS: 120), viaNetwork: false)
		try await Task.sleep(for: .seconds(2))
		out("  queue length while waiting: \(await bay.status().queue)\n")
		let b = uptimeNS()
		try await bay.release(held[0].id, saveCache: false)
		let served = try await waiting
		out(
			String(
				format: "  ok   waiting request served by capsule %d as %@, %.0f ms after the release\n", served.capsule, served.id, elapsedMS(b, uptimeNS())))
		for l in held.dropFirst() + [served] { try await bay.release(l.id, saveCache: false) }
		try await waitFor("capsules to refill", timeout: 120, every: 0.1) { await bay.status().capsules.allSatisfy { $0.state == "thawed" } }
		return failures
	}
}

import Foundation
import Virtualization

/// Timing lines for commands that want to show them (`lease-test`); the unified log gets them too.
@MainActor
enum BayTrace {
	static var sink: ((String) -> Void)?
	static func note(_ s: String) {
		BayLog.bay.info("\(s, privacy: .public)")
		sink?(s)
	}
}

// MARK: - Refill (shared by the bay and `thaw-test`)

/// A fresh Ed25519 key pair for one lease, made on the host.
struct LeaseKey {
	let privateKey: String
	let publicKey: String

	/// `ssh-keygen` into `<dir>/id_ed25519` (0600); the lease dir must exist.
	static func generate(in dir: URL, id: String) async throws -> LeaseKey {
		let file = dir.appending(path: "id_ed25519")
		let r = await runProcess("/usr/bin/ssh-keygen", ["-q", "-t", "ed25519", "-N", "", "-C", "cryo-\(id)", "-f", file.path])
		guard r.status == 0 else { throw BayError("ssh-keygen: \(r.out)") }
		let priv = try String(contentsOf: file, encoding: .utf8)
		let pub = try String(contentsOf: dir.appending(path: "id_ed25519.pub"), encoding: .utf8)
		return LeaseKey(privateKey: priv, publicKey: pub.trimmingCharacters(in: .whitespacesAndNewlines))
	}

	/// Guest command that appends the key from stdin to `authorized_keys`, keeping the image key
	/// (the bay's own door in) and starting a new line if the file didn't end with one.
	static let installCommand =
		"umask 077; mkdir -p ~/.ssh; f=~/.ssh/authorized_keys; touch $f; [ -z \"$(tail -c1 $f)\" ] || echo >> $f; cat >> $f"
}

/// One capsule brought to "paused, ready to lease".
struct Refilled {
	let thawed: ThawedCapsule
	let key: LeaseKey?
	/// The guest's new public host key (`ssh-ed25519 …`), pinned in the lease's ssh_config.
	let hostKey: String
	/// Timings in ms.
	let restoreMS: Double
	let upMS: Double
	let rekeyMS: Double
	let pauseMS: Double
}

/// A restore that worked, but whose guest never answered SSH (Freeze.activate timed out).
struct RestoredNotReady: Error, CustomStringConvertible {
	let underlying: Error
	var description: String { "restored, but the guest never got ready: \(underlying)" }
}

/// docs/spec/bay.md "Leases" (Restore problems): a readiness timeout gets a cold boot, then a
/// refreeze. One timeout can be a hiccup, so only after `limit` restores in a row whose guest never answered; from
/// then on every refill cold boots (which marks the capsule for refreeze) until a refreeze remakes
/// the state or a restore gets ready again.
struct NotReadyAfterRestore: Equatable {
	static let limit = 2
	private(set) var count = 0

	/// Why the next refill should skip the restore; nil to restore.
	var coldBootReason: String? {
		count >= Self.limit ? "the guest didn't answer SSH after \(count) restores in a row" : nil
	}

	mutating func refillFailed(_ error: Error) { if error is RestoredNotReady { count += 1 } }
	mutating func restoredAndReady() { count = 0 }
	mutating func refrozen() { count = 0 }
}

enum Refill {
	/// Restore (or cold boot) into `leases/<leaseID>/`, resume, readiness login with the clock, rekey
	/// the host with `HostName = cryo-<leaseID>`, optionally install a per-lease SSH key, three
	/// warm-up logins, pause. A lease is then resume + clock login. On failure the VM is
	/// stopped and the lease directory removed; a restored guest that never got ready throws
	/// `RestoredNotReady`. `coldBoot` skips the restore for that reason.
	@MainActor
	static func run(
		paths: BayPaths, image: ImageFiles, digest: String, capsule: CapsuleFiles, manifest: CapsuleManifest,
		guest: Guest, leaseID: String, installKey: Bool, coldBoot: String? = nil, beforeRekey: (@MainActor () async -> Void)? = nil
	) async throws -> Refilled {
		let t = try await CapsuleVM.thaw(
			paths: paths, image: image, digest: digest, capsule: capsule, manifest: manifest, leaseID: leaseID, coldBoot: coldBoot)
		do {
			if let why = t.fallbackReason { BayLog.vm.error("capsule \(capsule.number): refill cold booted: \(why, privacy: .public)") }
			let up: Freeze.Activation
			do {
				up = try await Freeze.activate(t.cvm, guest: guest, resume: !t.coldBooted)
			} catch  where !t.coldBooted {
				throw RestoredNotReady(underlying: error)
			}
			await beforeRekey?()
			let a = uptimeNS()
			let rekey = await guest.ssh(Guest.rekeyCommand(hostName: "cryo-\(leaseID)"))
			guard rekey.status == 0 else { throw BayError("rekey failed: \(rekey.out)") }
			guard let hostKey = Guest.rekeyedHostKey(from: rekey.out) else { throw BayError("rekey printed no host key: \(rekey.out)") }
			var key: LeaseKey?
			if installKey {
				let k = try await LeaseKey.generate(in: t.lease.dir, id: leaseID)
				let r = await guest.ssh(LeaseKey.installCommand, stdin: Data((k.publicKey + "\n").utf8))
				guard r.status == 0 else { throw BayError("install lease key: \(r.out)") }
				key = k
			}
			for _ in 0..<3 { await guest.ssh("true") }
			let b = uptimeNS()
			try await t.cvm.pause()
			return Refilled(
				thawed: t, key: key, hostKey: hostKey, restoreMS: t.restoreMS, upMS: up.total, rekeyMS: elapsedMS(a, b), pauseMS: elapsedMS(b, uptimeNS()))
		} catch {
			await CapsuleVM.release(t)
			throw error
		}
	}
}

// MARK: - Capsule state machine

/// What the bay's lease engine uses of a capsule, so tests can run `Bay` on fakes without VMs.
@MainActor
protocol LeaseCapsule: AnyObject, Sendable {
	var n: Int { get }
	var state: Capsule.State { get }
	var leaseID: String? { get }
	var leaseKey: LeaseKey? { get }
	var hostKey: String? { get }
	var guestIP: String { get }
	var isFree: Bool { get }
	var planEntry: RefreezePlan.Entry { get }
	var refreezeTries: Int { get }
	func refill(id: String) async throws -> Capsule.RefillTimings
	func markBroken()
	func claim()
	func unclaim()
	func startLease(folder: URL?, cache: String?) async throws -> Capsule.Timings
	func stopLease(saveCache: Bool) async -> [String]
	func markRefreezing()
	func refreeze(info: ImageInfo, out: @escaping BayCommand.Writer) async throws
}

/// One capsule position: frozen → refilling → thawed → leased → stopping → refilling → thawed.
/// `broken` after repeated refill failures; the bay keeps retrying it (RetryPolicy). A manifest
/// mismatch doesn't break it: the cold boot fallback still serves leases and the bay refreezes the
/// capsule in the background (`refreezing`, RefreezePlan). Nor do restores whose guest never
/// answers: after `NotReadyAfterRestore.limit` of them, refills cold boot and refreeze too.
@MainActor
final class Capsule: LeaseCapsule {
	enum State: String {
		case frozen, refilling, thawed, leased, stopping, refreezing, broken
	}

	let n: Int
	let paths: BayPaths
	let image: ImageFiles
	let digest: String
	private(set) var manifest: CapsuleManifest
	let guest: Guest

	private(set) var state: State = .frozen
	/// Id of the lease this capsule is prepared for (thawed) or serving (leased); nil otherwise.
	private(set) var leaseID: String?
	/// Cold boot fallback was used, so the saved state needs remaking (the bay refreezes it).
	private(set) var needsRefreeze = false
	/// Refreezes since the last refill that restored the saved state (RefreezePlan.maxTries).
	private(set) var refreezeTries = 0
	/// Restores whose guest never answered; past the limit, refills cold boot (and so refreeze).
	private(set) var notReady = NotReadyAfterRestore()

	private var refilled: Refilled?
	private var usb: VZUSBDevice?
	private var cacheName: String?

	init(n: Int, paths: BayPaths, image: ImageFiles, digest: String, manifest: CapsuleManifest) {
		self.n = n
		self.paths = paths
		self.image = image
		self.digest = digest
		self.manifest = manifest
		self.guest = Guest(ip: manifest.network.guestIP, key: image.guestKey)
	}

	var guestIP: String { manifest.network.guestIP }
	var isFree: Bool { state == .thawed }

	/// Refill timings in ms, for the bay's trace.
	struct RefillTimings {
		var restoreMS = 0.0, upMS = 0.0, rekeyMS = 0.0, pauseMS = 0.0
	}

	/// Makes the capsule ready for lease `id`: refill into `leases/<id>/`, then paused.
	@discardableResult
	func refill(id: String) async throws -> RefillTimings {
		state = .refilling
		leaseID = id
		do {
			let r = try await Refill.run(
				paths: paths, image: image, digest: digest, capsule: paths.capsule(n), manifest: manifest,
				guest: guest, leaseID: id, installKey: true, coldBoot: notReady.coldBootReason)
			if r.thawed.fallbackReason == nil { notReady.restoredAndReady() }
			needsRefreeze = RefreezePlan.needed(fallbackReason: r.thawed.fallbackReason)
			if needsRefreeze, let why = r.thawed.fallbackReason {
				BayTrace.note("capsule \(n) cold booted (\(why)); marked for refreeze")
			}
			if r.thawed.fallbackReason == nil { refreezeTries = 0 }
			refilled = r
			state = .thawed
			return RefillTimings(restoreMS: r.restoreMS, upMS: r.upMS, rekeyMS: r.rekeyMS, pauseMS: r.pauseMS)
		} catch {
			notReady.refillFailed(error)
			leaseID = nil
			state = .frozen
			throw error
		}
	}

	/// The quick retries failed (RetryPolicy); the bay keeps retrying with backoff.
	func markBroken() {
		state = .broken
	}

	/// The bay hands the thawed capsule to a lease (kept synchronous so two requests never get the same one).
	func claim() {
		precondition(state == .thawed)
		state = .leased
	}

	/// Gives a claimed capsule back untouched (the request was cancelled before startLease).
	func unclaim() {
		precondition(state == .leased)
		state = .thawed
	}

	/// The key made at refill time for the claimed lease.
	var leaseKey: LeaseKey? { refilled?.key }
	/// The host key the guest got at refill time.
	var hostKey: String? { refilled?.hostKey }

	struct Timings {
		var cloneMS = 0.0, resumeMS = 0.0, readyMS = 0.0, cacheMS = 0.0
	}

	/// Hands the claimed capsule to the lease: clone and swap the folder, resume, attach the cache,
	/// clock login. The lease id, host name and key were fixed at refill, so this is resume + login
	/// plus the inputs.
	func startLease(folder: URL?, cache: String?) async throws -> Timings {
		guard let r = refilled, state == .leased else { throw BayError("capsule \(n) is not claimed") }
		let lease = r.thawed.lease
		let cvm = r.thawed.cvm
		var t = Timings()

		let t0 = uptimeNS()
		if let folder { try await LeaseInputs.cloneFolder(folder, to: lease.folder) }
		let t1 = uptimeNS()
		t.cloneMS = elapsedMS(t0, t1)

		var isNew = false
		if let cache {
			isNew = try await LeaseInputs.prepareCache(name: cache, paths: paths, lease: lease)
			cacheName = cache
		}
		let t2 = uptimeNS()

		try await cvm.resume()
		if folder != nil { try LeaseInputs.swapShare(cvm, to: lease.folder) }
		if cache != nil { usb = try await LeaseInputs.attachCache(cvm, image: lease.cache) }
		let t3 = uptimeNS()
		t.resumeMS = elapsedMS(t2, t3)

		try await waitFor("SSH after resume", timeout: 60, every: 0.02) { await self.guest.probe() }
		try await waitFor("SSH login after resume", timeout: 60, every: 0.05) { await self.guest.ssh(Guest.clockCommand()).status == 0 }
		t.readyMS = elapsedMS(t3, uptimeNS())

		// The guest sees a swapped share after ~140 ms; wait for the folder's first entry so the
		// agent never gets an empty-looking /Volumes/My Shared Files.
		if let folder, let first = LeaseInputs.firstEntry(folder) {
			let path = LeaseInputs.shellQuote("\(LeaseInputs.shareMount)/\(first)")
			try await waitFor("the lease folder in the guest", timeout: 15, every: 0.05) { await self.guest.ssh("test -e \(path)").status == 0 }
		}
		let t4 = uptimeNS()
		if cache != nil { try await LeaseInputs.waitForCache(guest: guest, isNew: isNew) }
		t.cacheMS = elapsedMS(t4, uptimeNS())
		return t
	}

	/// Ends the lease: flush the cache (`sync`), detach it, host `stop()` (never a guest
	/// shutdown), move the cache into `caches/` when asked, delete `leases/<id>/`. Every
	/// step is best effort and logged, so the caller always gets to refill. Returns the problems.
	func stopLease(saveCache: Bool) async -> [String] {
		var problems: [String] = []
		guard let r = refilled else { return problems }
		state = .stopping
		let lease = r.thawed.lease
		let cvm = r.thawed.cvm
		let saving = saveCache && cacheName != nil && usb != nil

		let t0 = uptimeNS()
		if saving && cvm.state == .running {
			// `diskutil unmount` took ~11 s even with force and `sync` is instant, so flush and let the
			// host stop the VM: APFS is crash-consistent, and the next attach replays its journal.
			let u = await guest.ssh("sync")
			if u.status != 0 { problems.append("sync cache: \(u.out)") }
		}
		let t1 = uptimeNS()
		if let usb {
			do { try await LeaseInputs.detachCache(cvm, device: usb) } catch { problems.append("detach cache: \(error)") }
		}
		let t2 = uptimeNS()
		do { try await cvm.stop() } catch { problems.append("stop: \(error)") }
		let t3 = uptimeNS()
		if saving, let name = cacheName {
			do { try LeaseInputs.saveCache(name: name, paths: paths, lease: lease) } catch { problems.append("\(error)") }
		}
		try? FileManager.default.removeItem(at: lease.dir)
		BayTrace.note(
			"capsule \(n) stop: sync \(Int(elapsedMS(t0, t1))) ms, detach \(Int(elapsedMS(t1, t2))) ms, stop \(Int(elapsedMS(t2, t3))) ms, save+delete \(Int(elapsedMS(t3, uptimeNS()))) ms"
		)
		usb = nil
		cacheName = nil
		refilled = nil
		leaseID = nil
		for p in problems { BayLog.bay.error("capsule \(self.n) release: \(p, privacy: .public)") }
		return problems
	}

	var planEntry: RefreezePlan.Entry {
		RefreezePlan.Entry(n: n, state: state, needsRefreeze: needsRefreeze, tries: refreezeTries)
	}

	/// Taken out of service for a refreeze. Synchronous, so no lease can claim it meanwhile.
	func markRefreezing() {
		precondition(state == .thawed || state == .stopping)
		state = .refreezing
	}

	/// Remakes the saved state (Freeze.refreeze): drops the prepared VM first, so the freeze has its
	/// VM slot. Ends `frozen` either way; on failure the old state stays and the refill cold boots again.
	func refreeze(info: ImageInfo, out: @escaping BayCommand.Writer) async throws {
		if refilled != nil { _ = await stopLease(saveCache: false) }
		state = .refreezing
		refreezeTries += 1
		defer { state = .frozen }
		manifest = try await Freeze.refreeze(
			paths: paths, image: image, digest: digest, info: info, capsule: paths.capsule(n), manifest: manifest, out: out)
		needsRefreeze = false
		notReady.refrozen()
	}
}

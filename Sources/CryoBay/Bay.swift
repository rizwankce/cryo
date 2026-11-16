import CryoAPI
import Foundation

// MARK: - Pure lease logic (unit-tested without VMs)

/// Why a lease ended without the client asking.
enum EndReason: String, Equatable {
	case idle = "idle timeout"
	case maxLength = "maximum lease length"
	case restart = "bay restarted"
	case shutdown = "bay shut down"
}

/// Idle and maximum-length rules (docs/spec/bay.md "Leases", cli.md "Keeping a lease alive").
struct LeasePolicy: Equatable {
	var defaultIdleS: Int
	var maxLeaseS: Int
	/// A lease never lives longer than 24 h, whatever the config says.
	static let hardCapS = 86400

	init(config: BayConfig) {
		defaultIdleS = config.idleTimeoutS
		maxLeaseS = config.maxLeaseS
	}

	init(defaultIdleS: Int, maxLeaseS: Int) {
		self.defaultIdleS = defaultIdleS
		self.maxLeaseS = maxLeaseS
	}

	var capS: Int { min(maxLeaseS, Self.hardCapS) }

	/// The request's `idle_s`, or the default, never below 1 s and never above the cap.
	func idleS(requested: Int?) -> Int { min(max(requested ?? defaultIdleS, 1), capS) }

	func expiresAt(created: Date) -> Date { created.addingTimeInterval(Double(capS)) }
	func renewBy(now: Date, idleS: Int) -> Date { now.addingTimeInterval(Double(idleS)) }

	/// Past the maximum length always ends a lease; past `renew_by` only when no connection is open.
	func endReason(now: Date, renewBy: Date, expiresAt: Date, openConnections: Int) -> EndReason? {
		if now >= expiresAt { return .maxLength }
		if now >= renewBy && openConnections <= 0 { return .idle }
		return nil
	}

	/// Seconds a request waits for a capsule: its `wait_s`, else the config default; never negative.
	static func waitS(requested: Int?, config: BayConfig) -> Int { max(requested ?? config.waitDefaultS, 0) }
}

/// Lease ids are `L<n>`, with n increasing for the life of the bay (persisted in `next-lease`).
enum LeaseID {
	static func format(_ n: Int) -> String { "L\(n)" }

	static func number(_ id: String) -> Int? {
		guard id.hasPrefix("L"), let n = Int(id.dropFirst()), n >= 0 else { return nil }
		return n
	}

	/// Contents of `next-lease`: a single integer; anything unreadable restarts at 1, and the
	/// counter also skips past any id still present on disk so a lost file can't reuse one.
	static func next(stored: String?, onDisk: [String]) -> Int {
		let fromFile = stored.flatMap { Int($0.trimmingCharacters(in: .whitespacesAndNewlines)) } ?? 1
		let fromDisk = onDisk.compactMap(number).max().map { $0 + 1 } ?? 1
		return max(fromFile, fromDisk, 1)
	}
}

/// First come, first served: tickets in arrival order, removable when a request gives up.
struct WaitQueue: Equatable {
	private var tickets: [Int] = []
	private var counter = 0

	var count: Int { tickets.count }
	var isEmpty: Bool { tickets.isEmpty }

	mutating func enqueue() -> Int {
		counter += 1
		tickets.append(counter)
		return counter
	}

	mutating func popFirst() -> Int? { tickets.isEmpty ? nil : tickets.removeFirst() }

	@discardableResult
	mutating func remove(_ ticket: Int) -> Bool {
		guard let i = tickets.firstIndex(of: ticket) else { return false }
		tickets.remove(at: i)
		return true
	}
}

/// Why recent leases ended, newest last, so a later call on the id gets `lease_lost` instead of 404.
struct EndedLog: Equatable {
	private(set) var order: [String] = []
	private var reasons: [String: String] = [:]
	let limit: Int

	init(limit: Int = 100) { self.limit = limit }

	mutating func record(_ id: String, _ reason: String) {
		if reasons[id] == nil { order.append(id) }
		reasons[id] = reason
		while order.count > limit { reasons.removeValue(forKey: order.removeFirst()) }
	}

	func reason(_ id: String) -> String? { reasons[id] }
}

// MARK: - Bay

/// One lease while it runs.
private struct ActiveLease {
	var lease: Lease
	let capsule: any LeaseCapsule
	let cache: String?
	var idleS: Int
	var openConnections = 0
}

/// The capsule manager and lease engine behind the API (docs/spec/bay.md). Lives on the main
/// actor, where Virtualization.framework wants its objects; the protocol's async methods hop here.
@MainActor
public final class Bay: BayService {
	public static let bayVersion = "0.0.0-dev"

	public let paths: BayPaths
	private(set) var config = BayConfig()
	private var policy = LeasePolicy(config: BayConfig())
	private var imageInfo: ImageInfo?
	private var capsules: [any LeaseCapsule] = []
	private var active: [String: ActiveLease] = [:]
	private var ended = EndedLog()
	private(set) var queue = WaitQueue()
	private var waiters: [Int: CheckedContinuation<any LeaseCapsule, Error>] = [:]
	private var refills: [Int: Task<Void, Never>] = [:]
	/// Retries of broken capsules, waiting out their backoff.
	private var retries: [Int: Task<Void, Never>] = [:]
	/// Each capsule's last refill failure, cleared when it refills (for `RestartPolicy`).
	private var lastFailures: [Int: FailureKind] = [:]
	/// The person-facing alert for capsules whose last refill failed on a taken subnet.
	var subnetAlert: String? {
		SubnetAlert.text(stuck: lastFailures.filter { $0.value == .subnet }.map(\.key))
	}

	/// Called when only a new process can recover (`RestartPolicy`); `cryo bay start` exits.
	public var onRestartNeeded: (@MainActor () async -> Void)?
	/// The one background refreeze at a time (RefreezePlan).
	private var refreezeTask: Task<Void, Never>?
	/// Set by the code 6 watchdog when the host refuses VMs it should allow; cleared by the
	/// next successful refill.
	private(set) var hostProblem: String?
	private var expiryTask: Task<Void, Never>?
	private var nextLease = 1
	private var stopping = false
	/// `shutdown()` has finished.
	private var shutDown = false
	private var started = false
	private(set) var counters = HealthCounters()
	private var startedAt = uptimeNS()
	private var hostFacts: (facts: HostFacts, at: Date)?
	/// The host facts read in flight, shared by concurrent callers (status is polled).
	private var gathering: Task<HostFacts, Never>?
	/// Each capsule's saved-state check, reused like the host facts; a refreeze clears it.
	private var savedState: (problems: [Int: [String]], at: Date)?
	/// Start-up step 1 (bay.md): the capsules stay frozen until the host checks that gate thawing
	/// pass. `blockedBy` holds those failing checks; once they pass the gate stays open.
	private(set) var gatePassed = false
	private(set) var blockedBy: [DoctorCheck] = []
	private var doctorTask: Task<Void, Never>?
	/// How often a blocked bay re-reads the host; `/v1/doctor` and `/v1/status` re-check too.
	static let doctorRecheckS = 30

	/// How long one second of RetryPolicy backoff and of `wait_s` lasts; tests shorten it.
	var second: Duration = .seconds(1)
	/// The lease clock (`renew_by`); tests move it by hand.
	var now: () -> Date = Date.init
	/// Reads this Mac's host facts (five process spawns); tests swap in fixed ones.
	var gatherHostFacts: @MainActor (BayPaths) async -> HostFacts = { await HostFacts.gather(paths: $0) }

	public init(paths: BayPaths = .standard()) { self.paths = paths }

	var nextLeaseFile: URL { paths.root.appending(path: "next-lease") }

	// MARK: Start and stop

	/// Loads config and image, clears the leases of a previous run (a restart ends every lease),
	/// then refills every capsule; two refill in parallel. With `waitForRefills`, returns when all
	/// are thawed or broken; without, at once (`firstRefills()` waits), so the API can serve status
	/// and queue leases while the capsules come up.
	/// While host checks that gate thawing fail, returns at once with every capsule frozen and
	/// re-checks the host until they pass (`gatePassed`), then refills in the background.
	public func start(waitForRefills: Bool = true) async throws {
		guard !started else { return }
		CapsuleVM.prepareProcess()
		config = try BayConfig.load(paths.config)
		policy = LeasePolicy(config: config)
		guard let digest = config.image else {
			throw BayError("no image in \(paths.config.path); build one with `cryo image build`, then `cryo image use <digest>`")
		}
		let image = paths.image(digest)
		imageInfo = try BayJSON.read(ImageInfo.self, from: image.info)
		try paths.prepare()
		// Start-up step 2 (bay.md): stop leftover VMs so their vmnet subnets free up; a subnet
		// still taken (a process killed with SIGKILL) is retried by the refill loop.
		try await Cleanup.atStart(paths)

		clearStaleLeases()

		let numbers = Array(capsuleNumbers(paths).prefix(config.capsules))
		guard !numbers.isEmpty else { throw BayError("no capsules in \(paths.capsules.path); run `cryo image use <digest>` first") }
		for n in numbers {
			let manifest = try BayJSON.read(CapsuleManifest.self, from: paths.capsule(n).manifest)
			capsules.append(Capsule(n: n, paths: paths, image: image, digest: digest, manifest: manifest))
		}
		started = true
		startedAt = uptimeNS()
		BayLog.bay.info(
			"bay \(Self.bayVersion, privacy: .public) starting: image \(self.imageInfo?.tag ?? "?", privacy: .public), \(self.capsules.count) capsule(s)")

		await thawOrWait()
		expiryTask = Task { @MainActor [weak self] in
			while !Task.isCancelled {
				try? await Task.sleep(for: .seconds(5))
				self?.expire(now: Date())
				self?.planRefreeze()
			}
		}
		if waitForRefills { await firstRefills() }
	}

	/// A restart ends every lease (bay.md): ids still in `leases/` answer `lease_lost` and their
	/// folders go; the lease counter skips past them.
	func clearStaleLeases() {
		let fm = FileManager.default
		let stale = ((try? fm.contentsOfDirectory(atPath: paths.leases.path)) ?? []).filter { !$0.hasPrefix(".") }
		nextLease = LeaseID.next(stored: try? String(contentsOf: nextLeaseFile, encoding: .utf8), onDisk: stale)
		for id in stale {
			ended.record(id, EndReason.restart.rawValue)
			try? fm.removeItem(at: paths.leases.appending(path: id))
		}
	}

	/// Start-up step 1: refills every capsule if the host checks that gate thawing pass; otherwise
	/// leaves them frozen and re-checks the host every `doctorRecheckS` until they do.
	func thawOrWait() async {
		await refreshHostFacts(maxAge: 0)
		guard !openGate(hostChecks()) else { return }
		BayTrace.note(
			"not thawing: cryo doctor fails \(blockedBy.map(\.check).joined(separator: "; ")); re-checking every \(Self.doctorRecheckS) s (or set ignore_doctor = true in config.toml)"
		)
		doctorTask = Task { @MainActor [weak self] in
			while !Task.isCancelled {
				try? await Task.sleep(for: .seconds(Self.doctorRecheckS))
				guard let self, !self.gatePassed, !self.stopping else { return }
				_ = await self.doctor()
			}
		}
	}

	/// Waits for every capsule's first refill tries: each is then thawed or broken. Returns at once
	/// while the thaw gate is closed.
	public func firstRefills() async {
		for task in refills.values { await task.value }
		// Stay up even with none ready: each broken capsule keeps retrying (a subnet a SIGKILL left
		// taken frees up later), and a queued lease is served by the first that recovers.
		if gatePassed, !stopping, !capsules.contains(where: \.isFree) {
			BayTrace.note("no capsule ready yet; broken capsules keep retrying (see above), leases queue meanwhile")
		}
	}

	/// Stops every VM and deletes the lease directories.
	public func shutdown() async {
		stopping = true
		expiryTask?.cancel()
		doctorTask?.cancel()
		for (t, cont) in waiters {
			cont.resume(throwing: ServiceError.noCapacity("bay is shutting down"))
			_ = t
		}
		waiters.removeAll()
		queue = WaitQueue()
		let tasks = Array(refills.values) + Array(retries.values) + [refreezeTask].compactMap { $0 }
		for task in tasks { task.cancel() }
		await CapsuleVM.stopAll()
		for task in tasks { await task.value }
		await CapsuleVM.stopAll()
		for id in active.keys { ended.record(id, EndReason.shutdown.rawValue) }
		active.removeAll()
		for name in (try? FileManager.default.contentsOfDirectory(atPath: paths.leases.path)) ?? [] {
			try? FileManager.default.removeItem(at: paths.leases.appending(path: name))
		}
		shutDown = true
	}

	/// `shutdown()` on a signal: waits at most `limit` (launchd kills a job 20 s after SIGTERM), so
	/// stuck work can't keep the caller from stopping the VMs and exiting. Every VM was already
	/// stopped once by then, and `stopping` keeps refills from thawing new ones.
	public func shutdown(within limit: Duration) async {
		Task { @MainActor in await self.shutdown() }
		let deadline = ContinuousClock.now + limit
		while !shutDown && !Task.isCancelled && ContinuousClock.now < deadline { try? await Task.sleep(for: .milliseconds(20)) }
		if !shutDown { BayTrace.note("shutdown still waiting after \(limit); stopping the VMs anyway") }
	}

	private func allocateLeaseID() -> String {
		let n = nextLease
		nextLease += 1
		// Written before the id is used, so a crash can skip an id but never reuse one.
		try? String(nextLease).write(to: nextLeaseFile, atomically: true, encoding: .utf8)
		return LeaseID.format(n)
	}

	// MARK: Refill

	/// Refills one capsule in the background: quick tries 5 s apart (RetryPolicy); after those it is
	/// `broken` and retried with backoff for as long as the bay runs. `failures` carries the count
	/// into a later retry.
	private func startRefill(_ c: any LeaseCapsule, failures start: Int = 0) {
		retries.removeValue(forKey: c.n)
		refills[c.n] = Task { @MainActor [weak self] in
			guard let self else { return }
			var failures = start
			var retry: (delay: Int, kind: FailureKind)?
			while !self.stopping && !Task.isCancelled {
				let id = self.allocateLeaseID()
				let t0 = uptimeNS()
				do {
					let r = try await c.refill(id: id)
					let ms = Int(elapsedMS(t0, uptimeNS()))
					self.counters.refilled(ms: ms)
					BayTrace.note(
						"capsule \(c.n) refilled as \(id) in \(ms) ms (restore \(Int(r.restoreMS)), up \(Int(r.upMS)), rekey+key+warm \(Int(r.rekeyMS)), pause \(Int(r.pauseMS)))"
					)
					if failures > 0 { BayTrace.note("capsule \(c.n) recovered after \(failures) failed refill(s)") }
					self.lastFailures[c.n] = nil
					self.hostProblem = nil
					retry = nil
					break
				} catch {
					self.counters.refillFailed()
					failures += 1
					let kind = FailureKind.of(error)
					let delay = RetryPolicy.delayS(afterFailures: failures, kind: kind)
					BayTrace.note("capsule \(c.n) refill failed (\(failures) in a row), next try in \(delay) s: \(String(describing: error))")
					if kind == .vmLimit { await self.vmLimitRefused(failures: failures) }
					self.lastFailures[c.n] = kind
					if failures >= RetryPolicy.quickTries, let restart = self.onRestartNeeded,
						RestartPolicy.shouldRestart(
							lastFailures: self.lastFailures, capsules: self.capsules.count, liveVMs: Cleanup.liveVMs,
							leases: self.capsules.filter { $0.state == .leased }.count)
					{
						BayTrace.note(
							"every capsule's subnet is taken and nothing runs; exiting so launchd starts a fresh bay (vmnet doesn't reconnect in this process once InternetSharing restarts)"
						)
						self.onRestartNeeded = nil
						await restart()
						return
					}
					retry = (delay, kind)
					if failures >= RetryPolicy.quickTries || self.stopping { break }
					try? await Task.sleep(for: self.second * delay)
				}
			}
			self.refills[c.n] = nil
			if let retry, !self.stopping {
				c.markBroken()
				let backoff = self.second * retry.delay
				self.retries[c.n] = Task { @MainActor [weak self] in
					try? await Task.sleep(for: backoff)
					guard let self, !Task.isCancelled, !self.stopping else { return }
					self.startRefill(c, failures: failures)
				}
			} else {
				self.dispatch()
				self.planRefreeze()
			}
		}
	}

	/// The code 6 watchdog: the host refused a VM. Says why in the trace;
	/// a leaked VM count marks the host unhealthy in `doctor` (only a reboot clears it).
	/// Other VM processes are named, not stopped: they may be the owner's own freeze.
	private func vmLimitRefused(failures: Int) async {
		let others = await Cleanup.otherVMProcesses(includeImageCommands: true)
		let live = Cleanup.liveVMs
		switch VMLimitVerdict.of(liveVMs: live, otherProcesses: others.count, failures: failures) {
		case .otherProcesses:
			BayTrace.note("VM limit reached: other processes run VMs: \(others.map { "\($0.pid) \($0.command)" }.joined(separator: ", "))")
		case .ownVMs:
			BayTrace.note("VM limit reached: the bay itself runs \(live) VM(s)")
		case .settling:
			BayTrace.note("VM limit reached with \(live) running: the host is still freeing a stopped VM; retrying")
		case .leak:
			hostProblem = "the host refused a VM with only \(live) running (code 6): its VM count leaked; reboot the host"
			BayTrace.note(hostProblem!)
		}
	}

	// MARK: Refreeze

	/// Takes an idle capsule marked for refreeze out of service, when nothing waits (RefreezePlan).
	private func planRefreeze() {
		guard !stopping else { return }
		let pick = RefreezePlan.pickIdle(capsules.map(\.planEntry), refreezeRunning: refreezeTask != nil, waiting: queue.count)
		guard let n = pick, let c = capsules.first(where: { $0.n == n }) else { return }
		runRefreeze(c)
	}

	/// Refreezes one capsule in the background (Freeze.refreeze), then refills it either way:
	/// on failure the old state stays and the cold boot fallback keeps serving.
	private func runRefreeze(_ c: any LeaseCapsule) {
		guard let info = imageInfo else { return }
		c.markRefreezing()
		refreezeTask = Task { @MainActor [weak self] in
			guard let self else { return }
			let t0 = Date()
			BayTrace.note("capsule \(c.n) refreezing in the background (try \(c.refreezeTries + 1)/\(RefreezePlan.maxTries))")
			do {
				try await c.refreeze(info: info) { text in
					for line in text.split(separator: "\n") { BayTrace.note("capsule \(c.n) refreeze: \(line)") }
				}
				BayTrace.note(String(format: "capsule %d refrozen in %.0f s", c.n, Date().timeIntervalSince(t0)))
			} catch {
				BayTrace.note("capsule \(c.n) refreeze failed: \(String(describing: error))")
			}
			self.savedState = nil
			self.refreezeTask = nil
			if !self.stopping { self.startRefill(c) }
		}
	}

	/// Hands thawed capsules to the first waiters in line.
	private func dispatch() {
		while let c = capsules.first(where: \.isFree), let ticket = queue.popFirst() {
			guard let cont = waiters.removeValue(forKey: ticket) else { continue }
			c.claim()
			cont.resume(returning: c)
		}
	}

	private func acquire(waitS: Int) async throws -> any LeaseCapsule {
		if queue.isEmpty, let c = capsules.first(where: \.isFree) {
			c.claim()
			return c
		}
		guard waitS > 0 else { throw ServiceError.noCapacity("no capsule is free") }
		let ticket = queue.enqueue()
		// A client that hangs up cancels this task: leave the queue (onCancel hops to the main actor,
		// after the continuation below is registered, since we never suspend in between).
		return try await withTaskCancellationHandler {
			try await withCheckedThrowingContinuation { cont in
				waiters[ticket] = cont
				let timeout = second * waitS
				Task { @MainActor [weak self] in
					try? await Task.sleep(for: timeout)
					guard let self, self.queue.remove(ticket) else { return }
					self.waiters.removeValue(forKey: ticket)?.resume(throwing: ServiceError.noCapacity("no capsule became free within \(waitS) s"))
				}
			}
		} onCancel: {
			Task { @MainActor [weak self] in
				guard let self, self.queue.remove(ticket) else { return }
				self.waiters.removeValue(forKey: ticket)?.resume(throwing: CancellationError())
			}
		}
	}

	// MARK: Leases

	public func createLease(_ request: LeaseRequest, viaNetwork: Bool) async throws -> Lease {
		guard started, !stopping else { throw ServiceError.noCapacity("bay is not running") }
		guard gatePassed else {
			throw ServiceError.noCapacity("capsules stay frozen until cryo doctor passes: \(blockedBy.map(\.check).joined(separator: "; "))")
		}
		var folder: URL?
		if let f = request.folder, !f.isEmpty {
			guard !viaNetwork else { throw ServiceError.badRequest("folder is not allowed over the network listener") }
			var isDir: ObjCBool = false
			guard FileManager.default.fileExists(atPath: f, isDirectory: &isDir), isDir.boolValue else {
				throw ServiceError.badRequest("folder \(f) does not exist or is not a directory")
			}
			folder = URL(filePath: f, directoryHint: .isDirectory).standardizedFileURL
		}
		if let c = request.cache, !LeaseInputs.validCacheName(c) {
			throw ServiceError.badRequest("cache name must be 1-64 characters of a-z, 0-9, '.', '_' or '-'")
		}
		let idleS = policy.idleS(requested: request.idleS)
		let waitS = LeasePolicy.waitS(requested: request.waitS, config: config)

		let t0 = uptimeNS()
		let capsule = try await acquire(waitS: waitS)
		if Task.isCancelled {
			// Assigned just as the client left: put the prepared capsule back for the next in line.
			capsule.unclaim()
			dispatch()
			throw CancellationError()
		}
		guard let id = capsule.leaseID, let key = capsule.leaseKey, let hostKey = capsule.hostKey else {
			throw ServiceError.internal("capsule \(capsule.n) was handed out without a prepared lease")
		}
		let timings: Capsule.Timings
		do {
			timings = try await capsule.startLease(folder: folder, cache: request.cache)
		} catch {
			// A client that hung up mid-start (its waits throw on cancellation) isn't a failed lease.
			let cancelled = Task.isCancelled
			if !cancelled {
				BayLog.bay.error("lease \(id, privacy: .public) failed to start: \(String(describing: error), privacy: .public)")
				counters.leaseFailed()
			}
			await endCapsule(capsule, saveCache: false)
			if cancelled { throw CancellationError() }
			throw ServiceError.internal("could not start lease: \(error)")
		}
		if stopping {
			await endCapsule(capsule, saveCache: false)
			throw ServiceError.noCapacity("bay is shutting down")
		}
		if Task.isCancelled {
			// The client hung up while the lease started (1.6-2.5 s with a cache): nobody will use or
			// release it, so end it now instead of holding the capsule until the idle timeout.
			BayTrace.note("lease \(id) on capsule \(capsule.n): client left during start; ending it")
			await endCapsule(capsule, saveCache: false)
			throw CancellationError()
		}
		let now = self.now()
		let lease = Lease(
			id: id, name: request.name, capsule: capsule.n, state: "leased", createdAt: now,
			renewBy: policy.renewBy(now: now, idleS: idleS), expiresAt: policy.expiresAt(created: now),
			cache: request.cache, idleS: idleS,
			ssh: SSHInfo(user: Guest.user, host: "cryo-\(id)", key: key.privateKey, config: LeaseInputs.sshConfig(id: id), hostKey: hostKey))
		active[id] = ActiveLease(lease: lease, capsule: capsule, cache: request.cache, idleS: idleS)
		let total = Int(elapsedMS(t0, uptimeNS()))
		counters.leaseStarted(ms: total)
		BayTrace.note(
			"lease \(id) on capsule \(capsule.n): \(total) ms (clone \(Int(timings.cloneMS)), resume \(Int(timings.resumeMS)), ready \(Int(timings.readyMS)), cache \(Int(timings.cacheMS)))"
		)
		return lease
	}

	private func find(_ id: String) throws -> ActiveLease {
		if let l = active[id] { return l }
		if let why = ended.reason(id) { throw ServiceError.leaseLost(id, why) }
		throw ServiceError.notFound(id)
	}

	public func lease(_ id: String) async throws -> Lease { try find(id).lease }

	public func leases() async -> [Lease] {
		active.values.map(\.lease).sorted { (LeaseID.number($0.id) ?? 0) < (LeaseID.number($1.id) ?? 0) }
	}

	/// Activity: pushes `renew_by` out by the lease's idle timeout.
	private func touch(_ id: String) {
		guard var l = active[id] else { return }
		l.lease.renewBy = policy.renewBy(now: now(), idleS: l.idleS)
		active[id] = l
	}

	public func renew(_ id: String) async throws -> RenewResponse {
		_ = try find(id)
		touch(id)
		return RenewResponse(renewBy: active[id]!.lease.renewBy)
	}

	public func release(_ id: String, saveCache: Bool) async throws {
		guard let l = active.removeValue(forKey: id) else { throw ServiceError.notFound(id) }
		await endCapsule(l.capsule, saveCache: saveCache)
	}

	/// Stops the lease on a capsule, then refills it in the background. Errors are logged by the
	/// capsule; the refill happens either way.
	private func endCapsule(_ c: any LeaseCapsule, saveCache: Bool) async {
		_ = await c.stopLease(saveCache: saveCache)
		guard !stopping else { return }
		if RefreezePlan.afterLease(c.planEntry, refreezeRunning: refreezeTask != nil, waiting: queue.count) {
			runRefreeze(c)
		} else {
			startRefill(c)
		}
	}

	private func end(_ id: String, _ reason: EndReason) async {
		guard let l = active.removeValue(forKey: id) else { return }
		ended.record(id, reason.rawValue)
		counters.leaseEnded(reason)
		BayLog.bay.info("lease \(id, privacy: .public) ended: \(reason.rawValue, privacy: .public)")
		await endCapsule(l.capsule, saveCache: false)
	}

	/// The timer's work: end leases past their limits. Each end runs on its own task, so a slow
	/// stop never delays the next tick.
	func expire(now: Date) {
		for (id, l) in active {
			if let why = policy.endReason(now: now, renewBy: l.lease.renewBy, expiresAt: l.lease.expiresAt, openConnections: l.openConnections) {
				Task { @MainActor in await self.end(id, why) }
			}
		}
	}

	public func connectionOpened(_ id: String) async {
		guard var l = active[id] else { return }
		l.openConnections += 1
		active[id] = l
		touch(id)
	}

	public func connectionClosed(_ id: String) async {
		guard var l = active[id] else { return }
		l.openConnections = max(l.openConnections - 1, 0)
		active[id] = l
		touch(id)  // closing is activity too: the idle clock starts from the last use
	}

	public func connectTarget(_ id: String) async throws -> (host: String, port: Int) {
		(try find(id).capsule.guestIP, 22)
	}

	// MARK: Status and doctor

	public func status() async -> Status {
		let doctorOK = await doctor(hostFactsMaxAge: 60).allSatisfy(\.ok)
		return Status(
			bay: Status.Bay(
				version: Self.bayVersion, image: imageInfo?.tag ?? "none", doctor: doctorOK ? Status.doctorOK : Status.doctorFailing,
				blockedBy: gatePassed ? nil : blockedBy.map(\.check), alert: subnetAlert),
			capsules: capsules.map {
				Status.Capsule(n: $0.n, state: $0.state.rawValue, lease: $0.state == .leased || $0.state == .stopping ? $0.leaseID : nil)
			},
			queue: queue.count,
			health: counters.health(
				uptimeS: Int(elapsedMS(startedAt, uptimeNS()) / 1000), hostUptimeS: Host.uptimeS,
				diskFreeBytes: Host.diskFreeBytes(paths.root), thermal: Host.thermal))
	}

	/// Host checks (docs/spec/setup.md), then the image and capsules. The pf anchor needs root to
	/// read, so only the helper that loads it is checked.
	public func doctor() async -> [DoctorCheck] { await doctor(hostFactsMaxAge: 0) }

	/// `/v1/status` reuses host facts and saved-state checks up to a minute old; `/v1/doctor` (after
	/// a `--fix`) reads them fresh. A blocked bay starts thawing from here once the gating checks pass.
	func doctor(hostFactsMaxAge: TimeInterval) async -> [DoctorCheck] {
		await refreshHostFacts(maxAge: hostFactsMaxAge)
		let host = hostChecks()
		if started, !gatePassed, !stopping, openGate(host) {
			BayTrace.note("cryo doctor passes now: thawing")
		}
		var checks = host.map(\.result)
		if let digest = config.image {
			let image = paths.image(digest)
			let missing = [image.base, image.hardwareModel, image.auxTemplate, image.info, image.guestKey]
				.filter { !FileManager.default.fileExists(atPath: $0.path) }.map(\.lastPathComponent)
			checks.append(
				DoctorCheck(
					check: "image \(digest) present", ok: missing.isEmpty,
					fix: missing.isEmpty ? nil : "missing \(missing.joined(separator: ", ")); cryo image build"))
		} else {
			checks.append(DoctorCheck(check: "image configured", ok: false, fix: "set image in \(paths.config.path)"))
		}
		let saved = savedStateProblems(maxAge: hostFactsMaxAge)
		for c in capsules {
			let problems = saved[c.n] ?? []
			checks.append(
				DoctorCheck(
					check: "capsule \(c.n) saved state matches", ok: problems.isEmpty,
					fix: problems.isEmpty ? nil : problems.joined(separator: "; ") + " (cold boot fallback serves leases; refreeze)"))
			let stuck = lastFailures[c.n] == .subnet
			checks.append(
				DoctorCheck(
					check: "capsule \(c.n) usable", ok: c.state != .broken && !stuck,
					fix: stuck
						? "its vmnet subnet is taken: \(SubnetAlert.command), or reboot"
						: c.state == .broken ? "refills keep failing (the bay retries); see cryo logs" : nil))
		}
		checks.append(DoctorCheck(check: "host accepts VMs", ok: hostProblem == nil, fix: hostProblem))
		return checks
	}

	/// Reads the host facts unless some younger than `maxAge` exist. Callers arriving while a read
	/// runs share it, so a polled status spawns its processes once.
	private func refreshHostFacts(maxAge: TimeInterval) async {
		if let h = hostFacts, -h.at.timeIntervalSinceNow <= maxAge { return }
		let task: Task<HostFacts, Never>
		if let running = gathering {
			task = running
		} else {
			let gather = gatherHostFacts
			let paths = paths
			task = Task { @MainActor in await gather(paths) }
			gathering = task
		}
		let facts = await task.value
		if gathering == task { gathering = nil }
		hostFacts = (facts, Date())
	}

	/// Each capsule's `manifestProblems`, reused up to `maxAge` (it stamps files and reads the
	/// host's fingerprint); cleared when a capsule is refrozen.
	private func savedStateProblems(maxAge: TimeInterval) -> [Int: [String]] {
		if let s = savedState, -s.at.timeIntervalSinceNow <= maxAge { return s.problems }
		var problems: [Int: [String]] = [:]
		for c in capsules { problems[c.n] = manifestProblems(paths: paths, capsule: c.n, digest: config.image) }
		savedState = (problems, Date())
		return problems
	}

	private func hostChecks() -> [HostCheck] {
		HostDoctor.checks(
			hostFacts!.facts, capsules: config.capsules, capsuleMemoryGB: imageInfo?.memoryGB ?? HostDoctor.defaultCapsuleMemoryGB)
	}

	/// The thaw gate (start-up step 1): records what blocks it; when nothing does, opens it for
	/// good and starts refilling every capsule. Returns whether it is open.
	private func openGate(_ host: [HostCheck]) -> Bool {
		blockedBy = HostDoctor.blocking(host, ignore: config.ignoreDoctor)
		guard blockedBy.isEmpty else { return false }
		let ignored = HostDoctor.blocking(host, ignore: false)
		if !ignored.isEmpty {
			BayTrace.note("ignore_doctor = true: thawing although cryo doctor fails \(ignored.map(\.check).joined(separator: "; "))")
		}
		gatePassed = true
		for c in capsules { startRefill(c) }
		return true
	}
}

// MARK: - Tests

extension Bay {
	/// A running bay over the given (fake) capsules, without start()'s config, image and VM steps.
	/// `refillAll()` then fills them as start() does.
	/// With `gated`, the thaw gate starts closed and `thawOrWait()` opens it as start() does.
	convenience init(paths: BayPaths, config: BayConfig, capsules: [any LeaseCapsule], imageInfo: ImageInfo? = nil, gated: Bool = false) {
		self.init(paths: paths)
		self.config = config
		policy = LeasePolicy(config: config)
		self.capsules = capsules
		self.imageInfo = imageInfo
		started = true
		gatePassed = !gated  // a started bay whose host passed doctor, unless the test drives the gate
	}

	/// Refills every capsule and waits until each is thawed or broken.
	func refillAll() async {
		for c in capsules { startRefill(c) }
		for task in refills.values { await task.value }
	}
}

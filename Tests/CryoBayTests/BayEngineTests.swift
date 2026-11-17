import CryoAPI
import CryoServer
import Foundation
import Testing

@testable import CryoBay

// The lease engine in `Bay` (acquire, queue, renewal, expiry, refill retries) on fake capsules:
// no VMs, retry backoff and `wait_s` in milliseconds, and a hand-moved lease clock.

struct RefillFailed: Error {}

/// A capsule without a VM. Follows the real Capsule's state machine and records every move the real
/// one would trap on (its preconditions) or that would hand one capsule to two leases.
@MainActor
final class FakeCapsule: LeaseCapsule {
	let n: Int
	private(set) var state: Capsule.State = .frozen
	private(set) var leaseID: String?
	private(set) var leaseKey: LeaseKey?
	private(set) var hostKey: String?
	var guestIP: String { "192.168.6\(n).2" }
	var isFree: Bool { state == .thawed }
	var planEntry: RefreezePlan.Entry { .init(n: n, state: state, needsRefreeze: needsRefreeze, tries: refreezeTries) }
	private(set) var refreezeTries = 0
	/// The last refill cold booted, so the saved state needs remaking (as the real Capsule).
	private(set) var needsRefreeze = false

	/// The next this many refills fail.
	var failRefills = 0
	/// The next lease start fails.
	var failStart = false
	/// How long a lease start takes (a cache attach is 1.6-2.5 s); cancellation cuts it short.
	var startDelay: Duration?
	/// The saved state is unusable: every refill cold boots until a refreeze remakes it.
	var staleState = false
	/// Refreezes fail, leaving the stale state.
	var failRefreeze = false
	private(set) var refreezes = 0
	private(set) var refillAttempts = 0
	private(set) var timesBroken = 0
	/// The lease running on this capsule, and every lease it ran.
	private(set) var serving: String?
	private(set) var served: [String] = []
	private(set) var violations: [String] = []

	init(_ n: Int) { self.n = n }

	func refill(id: String) async throws -> Capsule.RefillTimings {
		if ![.frozen, .stopping, .broken].contains(state) { violations.append("refill \(id) while \(state)") }
		refillAttempts += 1
		state = .refilling
		leaseID = id
		try? await Task.sleep(for: .milliseconds(1))  // a real suspension, so other work interleaves
		if failRefills > 0 {
			failRefills -= 1
			leaseID = nil
			state = .frozen
			throw RefillFailed()
		}
		leaseKey = LeaseKey(privateKey: "key-\(id)", publicKey: "pub-\(id)")
		hostKey = "ssh-ed25519 host-\(id)"
		needsRefreeze = staleState
		if !staleState { refreezeTries = 0 }
		state = .thawed
		return .init()
	}

	func markBroken() {
		timesBroken += 1
		state = .broken
	}

	func claim() {
		if state != .thawed { violations.append("claim while \(state)") }
		state = .leased
	}

	func unclaim() {
		if state != .leased { violations.append("unclaim while \(state)") }
		state = .thawed
	}

	func startLease(folder: URL?, cache: String?) async throws -> Capsule.Timings {
		guard state == .leased, serving == nil, let id = leaseID else {
			violations.append("start lease while \(state), serving \(serving ?? "-")")
			throw RefillFailed()
		}
		serving = id
		served.append(id)
		await Task.yield()
		if let startDelay { try? await Task.sleep(for: startDelay) }
		if failStart {
			failStart = false
			throw RefillFailed()
		}
		return .init()
	}

	func stopLease(saveCache: Bool) async -> [String] {
		if state != .leased { violations.append("stop lease while \(state)") }
		state = .stopping
		await Task.yield()
		serving = nil
		leaseID = nil
		leaseKey = nil
		hostKey = nil
		return []
	}

	func markRefreezing() {
		if state != .thawed && state != .stopping { violations.append("refreeze while \(state)") }
		if !needsRefreeze { violations.append("refreeze without need") }
		state = .refreezing
	}

	func refreeze(info: ImageInfo, out: @escaping BayCommand.Writer) async throws {
		if state != .refreezing { violations.append("refreeze run while \(state)") }
		leaseID = nil  // the prepared VM is dropped first
		leaseKey = nil
		hostKey = nil
		refreezes += 1
		refreezeTries += 1
		defer { state = .frozen }
		try? await Task.sleep(for: .milliseconds(1))
		if failRefreeze { throw RefillFailed() }
		staleState = false
		needsRefreeze = false
	}
}

@MainActor
final class TestClock {
	var t = Date(timeIntervalSince1970: 1_000_000)
}

@MainActor
final class Arrivals {
	var names: [String] = []
}

@MainActor
func makeBay(_ capsules: [FakeCapsule], _ edit: (inout BayConfig) -> Void = { _ in }) -> Bay {
	var config = BayConfig()
	edit(&config)
	let root = FileManager.default.temporaryDirectory.appending(path: "cryo-engine-\(UUID().uuidString)")
	try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
	let bay = Bay(paths: BayPaths(root: root), config: config, capsules: capsules)
	bay.second = .milliseconds(1)
	return bay
}

/// Polls `condition` until it holds; records a failure after `timeout`.
@MainActor
func eventually(_ what: String, timeout: Duration = .seconds(10), _ condition: () -> Bool) async {
	let deadline = ContinuousClock.now + timeout
	while !condition() {
		if ContinuousClock.now > deadline {
			Issue.record("timed out waiting for \(what)")
			return
		}
		try? await Task.sleep(for: .milliseconds(1))
	}
}

/// Gives spawned tasks (expiry ends, refills) time to run, for checks that something did not happen.
@MainActor
func settle() async { try? await Task.sleep(for: .milliseconds(30)) }

@MainActor
@Suite("Bay lease engine")
struct BayEngineTests {
	func lease(_ bay: Bay, waitS: Int = 0, idleS: Int? = nil) async throws -> Lease {
		try await bay.createLease(LeaseRequest(waitS: waitS, idleS: idleS), viaNetwork: false)
	}

	func noViolations(_ caps: [FakeCapsule]) {
		for c in caps { #expect(c.violations.isEmpty, "capsule \(c.n): \(c.violations)") }
	}

	@Test func hundredsOfLeasesOnTwoCapsules() async throws {
		let caps = [FakeCapsule(1), FakeCapsule(2)]
		let bay = makeBay(caps)
		await bay.refillAll()

		// Four clients on two capsules, so requests queue all the time.
		let clients = (0..<4).map { _ in
			Task { @MainActor in
				var mine: [String] = []
				for _ in 0..<75 {
					do {
						let l = try await bay.createLease(LeaseRequest(waitS: 60), viaNetwork: false)
						#expect(caps[l.capsule - 1].serving == l.id)
						#expect(l.ssh.key == "key-\(l.id)" && l.ssh.hostKey == "ssh-ed25519 host-\(l.id)")
						mine.append(l.id)
						try await bay.release(l.id, saveCache: false)
					} catch {
						Issue.record("lease \(mine.count): \(error)")
					}
				}
				return mine
			}
		}
		var ids: [String] = []
		for c in clients { ids += await c.value }

		#expect(ids.count == 300 && Set(ids).count == 300)
		#expect(Set(caps.flatMap(\.served)) == Set(ids))
		#expect(caps.allSatisfy { $0.served.count > 50 })
		noViolations(caps)
		#expect(await bay.leases().isEmpty)
		#expect(bay.queue.isEmpty)
		await eventually("both capsules thawed") { caps.allSatisfy(\.isFree) }
		let h = bay.counters
		#expect(h.leasesServed == 300 && h.leasesFailed == 0 && h.leasesExpired == 0)
		#expect(h.refills == 302 && h.refillsFailed == 0)
	}

	@Test func queueIsFirstComeFirstServed() async throws {
		let caps = [FakeCapsule(1), FakeCapsule(2)]
		let bay = makeBay(caps)
		await bay.refillAll()
		let a = try await lease(bay)
		let b = try await lease(bay)
		await #expect(throws: ServiceError.noCapacity("no capsule is free")) { try await lease(bay) }

		let arrivals = Arrivals()
		func client(_ name: String, waitS: Int) -> Task<Lease?, Never> {
			Task { @MainActor in
				do {
					let l = try await lease(bay, waitS: waitS)
					arrivals.names.append(name)
					return l
				} catch {
					arrivals.names.append("\(name) gave up")
					return nil
				}
			}
		}
		let c1 = client("c1", waitS: 60_000)
		await eventually("c1 queued") { bay.queue.count == 1 }
		let c2 = client("c2", waitS: 300)  // gives up while queued
		await eventually("c2 queued") { bay.queue.count == 2 }
		let c3 = client("c3", waitS: 60_000)
		await eventually("c3 queued") { bay.queue.count == 3 }
		#expect(await c2.value == nil)
		#expect(arrivals.names == ["c2 gave up"])
		#expect(bay.queue.count == 2)

		try await bay.release(a.id, saveCache: false)
		let l1 = await c1.value
		#expect(arrivals.names == ["c2 gave up", "c1"])
		#expect(l1?.capsule == a.capsule)
		try await bay.release(b.id, saveCache: false)
		let l3 = await c3.value
		#expect(arrivals.names == ["c2 gave up", "c1", "c3"])
		#expect(l3?.capsule == b.capsule)
		#expect(bay.queue.isEmpty)
		noViolations(caps)
		#expect(bay.counters.leasesServed == 4)
	}

	@Test func leasesExpireWhenRenewalsStop() async throws {
		let caps = [FakeCapsule(1), FakeCapsule(2)]
		let clock = TestClock()
		let bay = makeBay(caps) { $0.maxLeaseS = 3600 }
		bay.now = { clock.t }
		await bay.refillAll()
		let t0 = clock.t
		func at(_ s: Double) {
			clock.t = t0.addingTimeInterval(s)
			bay.expire(now: clock.t)
		}
		func lost(_ id: String) async -> String? {
			do {
				_ = try await bay.lease(id)
				return nil
			} catch {
				return (error as? ServiceError)?.message
			}
		}

		let a = try await lease(bay, idleS: 60)
		let b = try await lease(bay, idleS: 60)
		at(50)
		_ = try await bay.renew(a.id)  // a: renew_by 110; b stops renewing at 60
		at(70)
		await settle()
		#expect(await lost(b.id) == "lease \(b.id) lost: idle timeout")
		#expect(await lost(a.id) == nil)

		// An open connection keeps a past its renew_by; closing it is activity too.
		await bay.connectionOpened(a.id)
		at(1070)
		await settle()
		#expect(await lost(a.id) == nil)
		await bay.connectionClosed(a.id)  // renew_by 1130
		at(1129)
		await settle()
		#expect(await lost(a.id) == nil)
		at(1131)
		await settle()
		#expect(await lost(a.id) == "lease \(a.id) lost: idle timeout")

		// The capsules came back; a busy lease still ends at the maximum length.
		await eventually("both capsules refilled") { caps.allSatisfy(\.isFree) }
		let c = try await lease(bay, idleS: 60)
		await bay.connectionOpened(c.id)
		at(1131 + 3599)
		await settle()
		#expect(await lost(c.id) == nil)
		at(1131 + 3600)
		await settle()
		#expect(await lost(c.id) == "lease \(c.id) lost: maximum lease length")

		noViolations(caps)
		#expect(await bay.leases().isEmpty)
		#expect(bay.counters.leasesServed == 3 && bay.counters.leasesExpired == 3)
	}

	@Test func refillFailsThenRecovers() async throws {
		let caps = [FakeCapsule(1), FakeCapsule(2)]
		let bay = makeBay(caps)
		caps[0].failRefills = 1
		await bay.refillAll()
		#expect(caps.allSatisfy { $0.isFree })
		#expect(caps[0].refillAttempts == 2 && caps[0].timesBroken == 0)

		// Two failures after a lease stay within the quick tries: never broken.
		let l = try await lease(bay)
		#expect(l.capsule == 1)
		caps[0].failRefills = 2
		try await bay.release(l.id, saveCache: false)
		await eventually("capsule 1 refilled") { caps[0].isFree }
		#expect(caps[0].refillAttempts == 5 && caps[0].timesBroken == 0)
		#expect(try await lease(bay).capsule == 1)
		#expect(try await lease(bay).capsule == 2)

		noViolations(caps)
		let h = bay.counters
		#expect(h.refills == 3 && h.refillsFailed == 3 && h.leasesServed == 3)
	}

	@Test func brokenCapsuleRetriesAndServesTheQueue() async throws {
		let caps = [FakeCapsule(1), FakeCapsule(2)]
		let bay = makeBay(caps)
		caps[0].failRefills = RetryPolicy.quickTries + 1
		await bay.refillAll()  // returns after the quick tries, as start() does
		#expect(caps[0].state == .broken && caps[0].timesBroken == 1)

		let b = try await lease(bay)
		#expect(b.capsule == 2)
		// Waits for capsule 1: one more failed retry (broken again), then it recovers.
		let waiter = try await lease(bay, waitS: 60_000)
		#expect(waiter.capsule == 1)
		#expect(caps[0].timesBroken == 2 && caps[0].refillAttempts == RetryPolicy.quickTries + 2)
		#expect(bay.queue.isEmpty)

		noViolations(caps)
		let h = bay.counters
		#expect(h.refills == 2 && h.refillsFailed == RetryPolicy.quickTries + 1 && h.leasesServed == 2)
	}

	@Test func leaseThatFailsToStartFreesItsCapsule() async throws {
		let caps = [FakeCapsule(1), FakeCapsule(2)]
		let bay = makeBay(caps)
		await bay.refillAll()
		caps[0].failStart = true
		await #expect(throws: ServiceError.self) { try await lease(bay) }
		#expect(await bay.leases().isEmpty)
		await eventually("capsule 1 refilled") { caps[0].isFree }
		#expect(try await lease(bay).capsule == 1)
		#expect(try await lease(bay).capsule == 2)

		noViolations(caps)
		let h = bay.counters
		#expect(h.leasesFailed == 1 && h.leasesServed == 2 && h.refills == 3 && h.leasesExpired == 0)
	}

	/// A client that hangs up while its lease starts gets no lease, and the capsule isn't held
	/// until the idle timeout; it isn't a failed lease either.
	@Test func clientLeavingDuringStartEndsTheLease() async throws {
		let caps = [FakeCapsule(1)]
		let bay = makeBay(caps)
		await bay.refillAll()
		caps[0].startDelay = .seconds(60)
		let client = Task { @MainActor in try await lease(bay) }
		await eventually("lease starting") { caps[0].serving != nil }
		client.cancel()
		await #expect(throws: CancellationError.self) { try await client.value }
		#expect(await bay.leases().isEmpty)
		await eventually("capsule 1 refilled") { caps[0].isFree }

		// The same when the start fails because the client left.
		caps[0].failStart = true
		let second = Task { @MainActor in try await lease(bay) }
		await eventually("second lease starting") { caps[0].serving != nil }
		second.cancel()
		await #expect(throws: CancellationError.self) { try await second.value }
		await eventually("capsule 1 refilled again") { caps[0].isFree }

		caps[0].startDelay = nil
		#expect(try await lease(bay).capsule == 1)
		noViolations(caps)
		let h = bay.counters
		#expect(h.leasesFailed == 0 && h.leasesServed == 1 && h.refills == 3)
	}

	@Test func queuedClientThatLeavesLeavesTheQueue() async throws {
		let caps = [FakeCapsule(1)]
		let bay = makeBay(caps)
		await bay.refillAll()
		let a = try await lease(bay)
		let waiter = Task { @MainActor in try await lease(bay, waitS: 60_000) }
		await eventually("waiter queued") { bay.queue.count == 1 }
		waiter.cancel()
		await #expect(throws: CancellationError.self) { try await waiter.value }
		#expect(bay.queue.isEmpty)

		// The freed capsule isn't handed to the client that left.
		try await bay.release(a.id, saveCache: false)
		await eventually("capsule 1 refilled") { caps[0].isFree }
		await settle()
		#expect(caps[0].isFree && caps[0].served == [a.id])
		#expect(try await lease(bay).capsule == 1)
		noViolations(caps)
	}

	/// Bad inputs are the client's fault (400) and never take a capsule.
	@Test func badLeaseInputsAreRefused() async throws {
		let caps = [FakeCapsule(1)]
		let bay = makeBay(caps)
		await bay.refillAll()
		let dir = FileManager.default.temporaryDirectory.appending(path: "cryo-inputs-\(UUID().uuidString)", directoryHint: .isDirectory)
		try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
		defer { try? FileManager.default.removeItem(at: dir) }
		let file = dir.appending(path: "file")
		try Data().write(to: file)
		func refusal(_ r: LeaseRequest, network: Bool = false) async -> ServiceError? {
			do {
				_ = try await bay.createLease(r, viaNetwork: network)
				return nil
			} catch {
				return error as? ServiceError
			}
		}
		#expect(await refusal(LeaseRequest(folder: dir.path), network: true) == .badRequest("folder is not allowed over the network listener"))
		#expect(await refusal(LeaseRequest(folder: dir.appending(path: "missing").path))?.status == 400)
		#expect(await refusal(LeaseRequest(folder: file.path))?.status == 400)
		#expect(await refusal(LeaseRequest(cache: "../x"))?.status == 400)
		#expect(await refusal(LeaseRequest(cache: "App"))?.status == 400)
		#expect(caps[0].isFree && caps[0].served.isEmpty)

		// A good folder over the socket is fine.
		let l = try await bay.createLease(LeaseRequest(folder: dir.path, cache: "app"), viaNetwork: false)
		#expect(l.capsule == 1 && l.cache == "app")
		noViolations(caps)
	}
}

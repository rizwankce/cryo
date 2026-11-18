import CryoAPI
import CryoServer
import Foundation
import Testing

@testable import CryoBay

// The bay around the lease engine, on fake capsules: the thaw gate, shutdown, a restart's stale
// leases, background refreezes, and what `/v1/status` costs.

/// Host facts the test changes by hand, and how often the bay read them.
@MainActor
final class FakeHost {
	var facts = DoctorTests.good
	var reads = 0
	/// How long a read takes, so concurrent callers overlap.
	var delay: Duration = .zero

	func install(on bay: Bay) {
		bay.gatherHostFacts = { [self] _ in
			reads += 1
			if delay > .zero { try? await Task.sleep(for: delay) }
			return facts
		}
	}
}

@MainActor
func fakeImage() -> ImageInfo {
	ImageInfo(digest: "d1", tag: "plain-27.2", macOS: "27.2", cpus: 4, memoryGB: 8, createdAt: Date(timeIntervalSince1970: 0))
}

@MainActor
func makeBay(_ capsules: [FakeCapsule], host: FakeHost, gated: Bool = false) -> Bay {
	let root = FileManager.default.temporaryDirectory.appending(path: "cryo-lifecycle-\(UUID().uuidString)")
	try? BayPaths(root: root).prepare()
	let bay = Bay(paths: BayPaths(root: root), config: BayConfig(), capsules: capsules, imageInfo: fakeImage(), gated: gated)
	bay.second = .milliseconds(1)
	host.install(on: bay)
	return bay
}

@MainActor
@Suite("Bay lifecycle")
struct BayLifecycleTests {
	func noViolations(_ caps: [FakeCapsule]) {
		for c in caps { #expect(c.violations.isEmpty, "capsule \(c.n): \(c.violations)") }
	}

	/// Start-up step 1: a host that fails a gating check keeps the capsules frozen and leases refused,
	/// status says why; a later doctor that passes thaws them without a restart.
	@Test func thawGateOpensOnALaterDoctor() async throws {
		let caps = [FakeCapsule(1), FakeCapsule(2)]
		let host = FakeHost()
		host.facts.screenLocked = true
		let bay = makeBay(caps, host: host, gated: true)
		await bay.thawOrWait()
		#expect(!bay.gatePassed && bay.blockedBy.map(\.check) == ["screen unlocked"])
		await bay.firstRefills()
		#expect(caps.allSatisfy { $0.state == .frozen && $0.refillAttempts == 0 })
		do {
			_ = try await bay.createLease(LeaseRequest(waitS: 60), viaNetwork: false)
			Issue.record("a blocked bay served a lease")
		} catch {
			let e = error as? ServiceError
			#expect(e?.code == APIError.noCapacity && e?.message.contains("screen unlocked") == true)
		}
		#expect(bay.queue.isEmpty)
		#expect(await bay.status().bay.blockedBy == ["screen unlocked"])

		// Fixed; status reuses the facts it has, so only a doctor run sees the fix.
		host.facts.screenLocked = false
		#expect(await bay.status().bay.blockedBy == ["screen unlocked"])
		_ = await bay.doctor()
		#expect(bay.gatePassed && bay.blockedBy.isEmpty)
		await bay.firstRefills()
		#expect(caps.allSatisfy { $0.isFree })
		#expect(await bay.status().bay.blockedBy == nil)
		let l = try await bay.createLease(LeaseRequest(waitS: 0), viaNetwork: false)
		#expect(caps[l.capsule - 1].serving == l.id)

		// Once open, the gate stays open.
		host.facts.screenLocked = true
		_ = await bay.doctor()
		#expect(bay.gatePassed)
		noViolations(caps)
		await bay.shutdown()
	}

	@Test func ignoreDoctorThawsABlockedHost() async throws {
		let caps = [FakeCapsule(1)]
		let host = FakeHost()
		host.facts.consoleOwner = "root"
		let root = FileManager.default.temporaryDirectory.appending(path: "cryo-lifecycle-\(UUID().uuidString)")
		var config = BayConfig()
		config.ignoreDoctor = true
		let bay = Bay(paths: BayPaths(root: root), config: config, capsules: caps, gated: true)
		bay.second = .milliseconds(1)
		host.install(on: bay)
		await bay.thawOrWait()
		await bay.firstRefills()
		#expect(bay.gatePassed && caps[0].isFree)
		#expect(await bay.status().bay.doctor == Status.doctorFailing)
	}

	/// Shutdown answers every waiter, ends every lease (a later call on its id says why, 410), and
	/// deletes the lease folders; nothing refills afterwards.
	@Test func shutdownEndsLeasesAndWaiters() async throws {
		let caps = [FakeCapsule(1)]
		let host = FakeHost()
		let bay = makeBay(caps, host: host)
		await bay.refillAll()
		let a = try await bay.createLease(LeaseRequest(waitS: 0), viaNetwork: false)
		try FileManager.default.createDirectory(at: bay.paths.lease(a.id).dir, withIntermediateDirectories: true)
		let waiter = Task { @MainActor in try await bay.createLease(LeaseRequest(waitS: 60_000), viaNetwork: false) }
		await eventually("waiter queued") { bay.queue.count == 1 }

		await bay.shutdown()
		await #expect(throws: ServiceError.noCapacity("bay is shutting down")) { try await waiter.value }
		await #expect(throws: ServiceError.leaseLost(a.id, EndReason.shutdown.rawValue)) { try await bay.lease(a.id) }
		#expect(ServiceError.leaseLost(a.id, "x").status == 410)
		#expect(await bay.leases().isEmpty)
		#expect(((try? FileManager.default.contentsOfDirectory(atPath: bay.paths.leases.path)) ?? []).isEmpty)
		await #expect(throws: ServiceError.noCapacity("bay is not running")) {
			try await bay.createLease(LeaseRequest(waitS: 0), viaNetwork: false)
		}
		let attempts = caps[0].refillAttempts
		await #expect(throws: ServiceError.self) { try await bay.release(a.id, saveCache: false) }
		await settle()
		#expect(caps[0].refillAttempts == attempts)
	}

	/// The signal path (`cryo bay start`): a broken capsule waiting out its backoff doesn't thaw
	/// after the shutdown, and a lease mid-start isn't registered on a stopping bay.
	@Test func shutdownOnASignalStopsRefillsAndStartingLeases() async throws {
		let caps = [FakeCapsule(1), FakeCapsule(2)]
		let bay = makeBay(caps, host: FakeHost())
		caps[0].failRefills = RetryPolicy.quickTries
		await bay.refillAll()
		#expect(caps[0].state == .broken)  // retries after a 30 ms backoff
		caps[1].startDelay = .milliseconds(200)
		let starting = Task { @MainActor in try await bay.createLease(LeaseRequest(waitS: 0), viaNetwork: false) }
		await eventually("lease starting") { caps[1].serving != nil }

		let t0 = ContinuousClock.now
		await bay.shutdown(within: .seconds(10))
		#expect(ContinuousClock.now - t0 < .seconds(5))
		await #expect(throws: ServiceError.noCapacity("bay is shutting down")) { try await starting.value }
		#expect(await bay.leases().isEmpty)
		let attempts = caps.map(\.refillAttempts)
		try await Task.sleep(for: .milliseconds(100))
		#expect(caps.map(\.refillAttempts) == attempts)
		#expect(caps[0].state == .broken)
	}

	/// A restart ends every lease: ids left in `leases/` answer lease_lost, and `next-lease` never
	/// hands out one of them again.
	@Test func staleLeasesFromARestart() async throws {
		let caps = [FakeCapsule(1)]
		let bay = makeBay(caps, host: FakeHost())
		let fm = FileManager.default
		try "5".write(to: bay.nextLeaseFile, atomically: true, encoding: .utf8)
		for id in ["L7", "L3"] { try fm.createDirectory(at: bay.paths.lease(id).dir, withIntermediateDirectories: true) }
		bay.clearStaleLeases()
		await #expect(throws: ServiceError.leaseLost("L7", EndReason.restart.rawValue)) { try await bay.lease("L7") }
		await #expect(throws: ServiceError.leaseLost("L3", EndReason.restart.rawValue)) { try await bay.lease("L3") }
		await #expect(throws: ServiceError.notFound("L4")) { try await bay.lease("L4") }
		#expect(((try? fm.contentsOfDirectory(atPath: bay.paths.leases.path)) ?? []).isEmpty)

		await bay.refillAll()
		#expect(caps[0].leaseID == "L8")
		// Written before the id is used, so a crash can skip an id but never reuse one.
		#expect(try String(contentsOf: bay.nextLeaseFile, encoding: .utf8) == "9")
		let l = try await bay.createLease(LeaseRequest(waitS: 0), viaNetwork: false)
		#expect(l.id == "L8")
	}

	/// A cold booted capsule is refrozen in the background while idle, then refilled from its new state.
	@Test func idleColdBootedCapsuleIsRefrozen() async throws {
		let caps = [FakeCapsule(1), FakeCapsule(2)]
		caps[0].staleState = true
		let bay = makeBay(caps, host: FakeHost())
		await bay.refillAll()
		await eventually("capsule 1 refrozen and refilled") { caps[0].refreezes == 1 && caps[0].isFree }
		#expect(!caps[0].needsRefreeze && caps[1].refreezes == 0)
		await settle()
		#expect(caps[0].refreezes == 1)
		noViolations(caps)
	}

	/// A waiting request is served by the cold boot at once; the refreeze waits until the lease ends.
	@Test func refreezeWaitsForTheQueueAndRunsAfterTheLease() async throws {
		let caps = [FakeCapsule(1)]
		let bay = makeBay(caps, host: FakeHost())
		await bay.refillAll()
		let a = try await bay.createLease(LeaseRequest(waitS: 0), viaNetwork: false)
		let waiter = Task { @MainActor in try await bay.createLease(LeaseRequest(waitS: 60_000), viaNetwork: false) }
		await eventually("waiter queued") { bay.queue.count == 1 }
		caps[0].staleState = true  // the next refill cold boots
		try await bay.release(a.id, saveCache: false)
		let w = try await waiter.value
		#expect(caps[0].serving == w.id && caps[0].needsRefreeze && caps[0].refreezes == 0)
		try await bay.release(w.id, saveCache: false)
		await eventually("refrozen after the lease, then refilled") { caps[0].refreezes == 1 && caps[0].isFree }
		#expect(!caps[0].needsRefreeze)
		noViolations(caps)
	}

	/// A refreeze that doesn't fix the state stops after RefreezePlan.maxTries; the cold boot keeps serving.
	@Test func failingRefreezeIsBounded() async throws {
		let caps = [FakeCapsule(1)]
		caps[0].staleState = true
		caps[0].failRefreeze = true
		let bay = makeBay(caps, host: FakeHost())
		await bay.refillAll()
		await eventually("refreeze tries used up") { caps[0].refreezes == RefreezePlan.maxTries && caps[0].isFree }
		bay.expire(now: Date())
		await settle()
		#expect(caps[0].refreezes == RefreezePlan.maxTries)
		#expect(try await bay.createLease(LeaseRequest(waitS: 0), viaNetwork: false).capsule == 1)
		noViolations(caps)
	}

	/// `/v1/status` is polled (lease-test every 100 ms): concurrent calls share one host read, and
	/// status reuses facts up to a minute old; `/v1/doctor` reads fresh.
	@Test func statusSharesHostReads() async throws {
		let caps = [FakeCapsule(1)]
		let host = FakeHost()
		host.delay = .milliseconds(50)
		let bay = makeBay(caps, host: host)
		let calls = (0..<5).map { _ in Task { @MainActor in await bay.status() } }
		for c in calls { _ = await c.value }
		#expect(host.reads == 1)
		_ = await bay.status()
		#expect(host.reads == 1)
		_ = await bay.doctor()
		#expect(host.reads == 2)
	}

	/// Status reuses each capsule's saved-state check; doctor re-reads it, and a refreeze clears it.
	@Test func savedStateCheckIsCached() async throws {
		let caps = [FakeCapsule(1)]
		let bay = makeBay(caps, host: FakeHost())
		func savedState() async -> String? {
			await bay.doctor(hostFactsMaxAge: 60).first { $0.check == "capsule 1 saved state matches" }?.fix
		}
		#expect(await savedState()?.hasPrefix("manifest.json missing") == true)
		// A manifest appears: status keeps the old answer, a full doctor sees it.
		try FileManager.default.createDirectory(at: bay.paths.capsule(1).dir, withIntermediateDirectories: true)
		let m = CapsuleManifest(
			image: "d1", cpus: 4, memoryGB: 8, mac: "12:ab:cd:10:20:31", network: CapsuleNetwork(subnet: 1), vsock: true,
			inputs: true, host: "elsewhere", files: [:], frozenAt: Date(timeIntervalSince1970: 0))
		try BayJSON.write(m, to: bay.paths.capsule(1).manifest)
		#expect(await savedState()?.hasPrefix("manifest.json missing") == true)
		_ = await bay.doctor()
		#expect(await savedState()?.contains("host: frozen elsewhere") == true)

		// A refreeze clears it.
		try FileManager.default.removeItem(at: bay.paths.capsule(1).manifest)
		caps[0].staleState = true
		await bay.refillAll()
		await eventually("capsule 1 refrozen") { caps[0].refreezes == 1 && caps[0].isFree }
		#expect(await savedState()?.hasPrefix("manifest.json missing") == true)
	}
}

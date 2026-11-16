import CryoAPI
import Foundation
import Testing

@testable import CryoBay

@Suite("Lease policy")
struct LeasePolicyTests {
	let policy = LeasePolicy(defaultIdleS: 3600, maxLeaseS: 86400)
	let t0 = Date(timeIntervalSince1970: 1_000_000)

	@Test func idleDefaultsAndCaps() {
		#expect(policy.idleS(requested: nil) == 3600)
		#expect(policy.idleS(requested: 300) == 300)
		#expect(policy.idleS(requested: 999_999) == 86400)
		#expect(policy.idleS(requested: 0) == 1)
		#expect(LeasePolicy(defaultIdleS: 3600, maxLeaseS: 600).idleS(requested: nil) == 600)
		// Config can't raise the 24 h hard cap.
		#expect(LeasePolicy(defaultIdleS: 10, maxLeaseS: 999_999).capS == 86400)
	}

	@Test func expiryAndRenewMath() {
		#expect(policy.expiresAt(created: t0) == t0.addingTimeInterval(86400))
		#expect(policy.renewBy(now: t0, idleS: 300) == t0.addingTimeInterval(300))
	}

	@Test func idleOnlyWithoutConnections() {
		let renewBy = t0.addingTimeInterval(300)
		let expires = t0.addingTimeInterval(86400)
		func reason(_ at: Double, _ open: Int) -> EndReason? {
			policy.endReason(now: t0.addingTimeInterval(at), renewBy: renewBy, expiresAt: expires, openConnections: open)
		}
		#expect(reason(299, 0) == nil)
		#expect(reason(300, 0) == .idle)
		#expect(reason(5000, 1) == nil)  // an open connection keeps it alive
		#expect(reason(86399, 2) == nil)
		#expect(reason(86400, 2) == .maxLength)  // ...but not past 24 h
		#expect(reason(86400, 0) == .maxLength)
	}

	@Test func waitSeconds() {
		var c = BayConfig()
		c.waitDefaultS = 600
		#expect(LeasePolicy.waitS(requested: nil, config: c) == 600)
		#expect(LeasePolicy.waitS(requested: 0, config: c) == 0)
		#expect(LeasePolicy.waitS(requested: -5, config: c) == 0)
		#expect(LeasePolicy.waitS(requested: 5, config: c) == 5)
	}
}

@Suite("Queue and ids")
struct QueueTests {
	@Test func firstComeFirstServed() {
		var q = WaitQueue()
		let a = q.enqueue()
		let b = q.enqueue()
		let c = q.enqueue()
		#expect(q.count == 3)
		let first = q.popFirst()
		let gaveUp = q.remove(c)  // gave up while waiting
		let again = q.remove(c)
		let second = q.popFirst()
		let none = q.popFirst()
		#expect(first == a)
		#expect(gaveUp)
		#expect(!again)
		#expect(second == b)
		#expect(none == nil)
		#expect(q.isEmpty)
	}

	@Test func ticketsNeverRepeat() {
		var q = WaitQueue()
		let a = q.enqueue()
		_ = q.popFirst()
		let b = q.enqueue()
		#expect(b != a)
	}

	@Test func leaseIDs() {
		#expect(LeaseID.format(81) == "L81")
		#expect(LeaseID.number("L81") == 81)
		#expect(LeaseID.number("81") == nil)
		#expect(LeaseID.number("Lx") == nil)
		#expect(LeaseID.next(stored: nil, onDisk: []) == 1)
		#expect(LeaseID.next(stored: "42\n", onDisk: []) == 42)
		#expect(LeaseID.next(stored: "garbage", onDisk: []) == 1)
		// A lost counter file can't reuse an id that is still on disk.
		#expect(LeaseID.next(stored: nil, onDisk: ["L7", "L3", "verify-0"]) == 8)
		#expect(LeaseID.next(stored: "50", onDisk: ["L7"]) == 50)
	}

	@Test func endedLogKeepsTheNewest() {
		var log = EndedLog(limit: 3)
		for i in 1...5 { log.record("L\(i)", "r\(i)") }
		#expect(log.reason("L1") == nil)
		#expect(log.reason("L2") == nil)
		#expect(log.reason("L3") == "r3")
		#expect(log.reason("L5") == "r5")
		log.record("L5", "again")
		#expect(log.reason("L5") == "again")
		#expect(log.order.count == 3)
	}

	@Test func healthCountsOnlyTheBaysOwnExpiries() {
		var c = HealthCounters()
		c.leaseStarted(ms: 900)
		c.leaseStarted(ms: 700)
		c.leaseFailed()
		for r in [EndReason.idle, .maxLength, .restart, .shutdown] { c.leaseEnded(r) }
		c.refillFailed()
		c.refilled(ms: 3100)
		let h = c.health(uptimeS: 5, hostUptimeS: 9, diskFreeBytes: nil, thermal: "nominal")
		#expect(
			h
				== Status.Health(
					uptimeS: 5, hostUptimeS: 9, thermal: "nominal", leasesServed: 2, leasesFailed: 1, leasesExpired: 2,
					refills: 1, refillsFailed: 1, lastLeaseMS: 700, lastRefillMS: 3100))
	}
}

@Suite("Readiness fallback")
struct NotReadyAfterRestoreTests {
	struct Other: Error {}

	/// bay.md "Leases" (Restore problems): a guest that never answers after a restore gets a cold boot (and so a
	/// refreeze), but not on the first timeout, and other failures don't count.
	@Test func coldBootsAfterRepeatedTimeoutsOnly() {
		var n = NotReadyAfterRestore()
		#expect(n.coldBootReason == nil)
		n.refillFailed(RestoredNotReady(underlying: Other()))
		#expect(n.coldBootReason == nil)  // one timeout can be a hiccup
		n.refillFailed(Other())  // a subnet or rekey failure says nothing about the saved state
		#expect(n.coldBootReason == nil)
		n.refillFailed(RestoredNotReady(underlying: Other()))
		let why = n.coldBootReason
		#expect(why != nil)
		#expect(RefreezePlan.needed(fallbackReason: why))
		// Cold boots succeed, but keep cold booting until the state is remade.
		#expect(n.coldBootReason != nil)
		n.refrozen()
		#expect(n.coldBootReason == nil)
		n.refillFailed(RestoredNotReady(underlying: Other()))
		n.restoredAndReady()
		n.refillFailed(RestoredNotReady(underlying: Other()))
		#expect(n.coldBootReason == nil)
	}
}

@Suite("Lease inputs")
struct LeaseInputsTests {
	@Test func cacheNames() {
		for ok in ["app", "my-app_1.2", "a", String(repeating: "x", count: 64), "0"] {
			#expect(LeaseInputs.validCacheName(ok), "\(ok)")
		}
		for bad in ["", "App", "a b", "a/b", "../x", ".", "..", "...", "é", String(repeating: "x", count: 65), "a\nb"] {
			#expect(!LeaseInputs.validCacheName(bad), "\(bad)")
		}
	}

	@Test func sshConfigShape() {
		#expect(
			LeaseInputs.sshConfig(id: "L81")
				== "Host cryo-L81\n  User cryo\n  ProxyCommand cryo ssh L81\n  IdentityFile ~/.cryo/keys/L81\n  HostKeyAlias cryo-L81\n"
				+ "  UserKnownHostsFile ~/.cryo/known_hosts/L81\n  GlobalKnownHostsFile /dev/null\n  StrictHostKeyChecking yes")
	}

	@Test func shellQuoting() {
		#expect(LeaseInputs.shellQuote("/Volumes/My Shared Files") == "'/Volumes/My Shared Files'")
		#expect(LeaseInputs.shellQuote("it's") == "'it'\\''s'")
	}

	@Test func externalDiskOnlyWhenUnambiguous() {
		let one = "/dev/disk4 (external, physical):\n   #:  TYPE NAME  SIZE IDENTIFIER\n   0: GUID_partition_scheme  *68.7 GB  disk4\n"
		#expect(LeaseInputs.externalDisk(from: one) == "/dev/disk4")
		#expect(LeaseInputs.externalDisk(from: one + "\n" + one.replacingOccurrences(of: "disk4", with: "disk5")) == nil)
		#expect(LeaseInputs.externalDisk(from: "") == nil)
		#expect(LeaseInputs.externalDisk(from: "/dev/disk3 (synthesized):\n") == nil)
	}

	@Test func cloneFolderKeepsTheOriginal() async throws {
		let fm = FileManager.default
		let dir = fm.temporaryDirectory.appending(path: "cryo-clone-\(UUID().uuidString)", directoryHint: .isDirectory)
		defer { try? fm.removeItem(at: dir) }
		let src = dir.appending(path: "src", directoryHint: .isDirectory)
		try fm.createDirectory(at: src.appending(path: "sub"), withIntermediateDirectories: true)
		try "hello".write(to: src.appending(path: "sub/a.txt"), atomically: true, encoding: .utf8)
		let dst = dir.appending(path: "dst", directoryHint: .isDirectory)
		try await LeaseInputs.cloneFolder(src, to: dst)
		try "changed".write(to: dst.appending(path: "sub/a.txt"), atomically: true, encoding: .utf8)
		#expect(try String(contentsOf: src.appending(path: "sub/a.txt"), encoding: .utf8) == "hello")
		#expect(LeaseInputs.firstEntry(dst) == "sub")
	}

	@Test func cacheSaveReplacesAtomically() throws {
		let fm = FileManager.default
		let root = fm.temporaryDirectory.appending(path: "cryo-cache-\(UUID().uuidString)", directoryHint: .isDirectory)
		defer { try? fm.removeItem(at: root) }
		let paths = BayPaths(root: root)
		try paths.prepare()
		try "old".write(to: paths.cache("app"), atomically: true, encoding: .utf8)
		let lease = paths.lease("L1")
		try fm.createDirectory(at: lease.dir, withIntermediateDirectories: true)
		try "new".write(to: lease.cache, atomically: true, encoding: .utf8)
		try LeaseInputs.saveCache(name: "app", paths: paths, lease: lease)
		#expect(try String(contentsOf: paths.cache("app"), encoding: .utf8) == "new")
		#expect(!fm.fileExists(atPath: lease.cache.path))
	}
}

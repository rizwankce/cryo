import Foundation
import Testing
import Virtualization

@testable import CryoBay

@Suite("Recovery decisions")
struct RecoveryTests {
	@Test func failureKinds() {
		let code6 = NSError(domain: VZErrorDomain, code: VZError.Code.virtualMachineLimitExceeded.rawValue)
		#expect(FailureKind.of(code6) == .vmLimit)
		// Same code in another domain, or another VZ code (12 = restore), is not the VM limit.
		#expect(FailureKind.of(NSError(domain: NSPOSIXErrorDomain, code: 6)) == .other)
		#expect(FailureKind.of(NSError(domain: VZErrorDomain, code: 12)) == .other)
		#expect(FailureKind.of(VMNetUnavailable(subnet: 1, status: 1001)) == .subnet)
		#expect(FailureKind.of(BayError("rekey failed")) == .other)
	}

	@Test func retryBackoff() {
		// Quick tries first, then backoff that keeps going (a broken capsule is never given up on).
		#expect(RetryPolicy.delayS(afterFailures: 1, kind: .other) == 5)
		#expect(RetryPolicy.delayS(afterFailures: 2, kind: .other) == 5)
		#expect(RetryPolicy.delayS(afterFailures: 3, kind: .other) == 30)
		#expect(RetryPolicy.delayS(afterFailures: 4, kind: .other) == 60)
		#expect(RetryPolicy.delayS(afterFailures: 7, kind: .other) == 480)
		#expect(RetryPolicy.delayS(afterFailures: 8, kind: .other) == 600)
		#expect(RetryPolicy.delayS(afterFailures: 1000, kind: .other) == 600)
		// A taken subnet frees itself when InternetSharing idles out: keep checking every minute.
		#expect(RetryPolicy.delayS(afterFailures: 3, kind: .subnet) == 30)
		#expect(RetryPolicy.delayS(afterFailures: 6, kind: .subnet) == 60)
		#expect(RetryPolicy.delayS(afterFailures: 1000, kind: .vmLimit) == 600)
	}

	@Test func vmLimitWatchdog() {
		#expect(VMLimitVerdict.of(liveVMs: 0, otherProcesses: 0) == .leak)
		#expect(VMLimitVerdict.of(liveVMs: 1, otherProcesses: 0) == .leak)
		#expect(VMLimitVerdict.of(liveVMs: 2, otherProcesses: 0) == .ownVMs)
		// Another process explains the refusal even when the bay runs few VMs.
		#expect(VMLimitVerdict.of(liveVMs: 1, otherProcesses: 1) == .otherProcesses)
		// A refusal right after a stop is the host catching up, not a leak.
		#expect(VMLimitVerdict.of(liveVMs: 1, otherProcesses: 0, failures: 1) == .settling)
		#expect(VMLimitVerdict.of(liveVMs: 1, otherProcesses: 0, failures: 2) == .settling)
		#expect(VMLimitVerdict.of(liveVMs: 1, otherProcesses: 0, failures: 3) == .leak)
		#expect(VMLimitVerdict.of(liveVMs: 2, otherProcesses: 0, failures: 1) == .ownVMs)
	}

	typealias E = RefreezePlan.Entry

	@Test func refreezeOnlyAfterRealFallback() {
		#expect(!RefreezePlan.needed(fallbackReason: nil))
		#expect(RefreezePlan.needed(fallbackReason: "restore failed: VZErrorDomain 12"))
		#expect(RefreezePlan.needed(fallbackReason: "host: frozen a, now b"))
		#expect(!RefreezePlan.needed(fallbackReason: RefreezePlan.forcedReason))
	}

	@Test func refreezeWarmUp() {
		// Manifests from before `warm_up` was recorded: an Xcode image gets the iOS warm-up back.
		#expect(RefreezePlan.warmUp(recorded: nil, imageTag: "xcode-27.2") == ["ios"])
		#expect(RefreezePlan.warmUp(recorded: nil, imageTag: "macos-27.2") == nil)
		// What a newer manifest recorded always wins, including "none" on an Xcode image.
		#expect(RefreezePlan.warmUp(recorded: [], imageTag: "xcode-27.2") == nil)
		#expect(RefreezePlan.warmUp(recorded: ["ios", "macos"], imageTag: "xcode-27.2") == ["ios", "macos"])
		#expect(RefreezePlan.warmUp(recorded: ["macos"], imageTag: "macos-27.2") == ["macos"])
	}

	@Test func refreezeAfterLease() {
		let marked = E(n: 0, state: .stopping, needsRefreeze: true, tries: 0)
		#expect(RefreezePlan.afterLease(marked, refreezeRunning: false, waiting: 0))
		#expect(!RefreezePlan.afterLease(marked, refreezeRunning: true, waiting: 0))  // one at a time
		#expect(!RefreezePlan.afterLease(marked, refreezeRunning: false, waiting: 1))  // a waiter gets the cold boot
		#expect(!RefreezePlan.afterLease(E(n: 0, state: .stopping, needsRefreeze: false, tries: 0), refreezeRunning: false, waiting: 0))
		#expect(RefreezePlan.afterLease(E(n: 0, state: .stopping, needsRefreeze: true, tries: 2), refreezeRunning: false, waiting: 0))
		#expect(!RefreezePlan.afterLease(E(n: 0, state: .stopping, needsRefreeze: true, tries: 3), refreezeRunning: false, waiting: 0))
	}

	@Test func refreezePicksIdleCapsule() {
		let entries = [
			E(n: 0, state: .leased, needsRefreeze: true, tries: 0),  // busy: waits for its release
			E(n: 1, state: .thawed, needsRefreeze: true, tries: 0),
		]
		#expect(RefreezePlan.pickIdle(entries, refreezeRunning: false, waiting: 0) == 1)
		#expect(RefreezePlan.pickIdle(entries, refreezeRunning: true, waiting: 0) == nil)
		#expect(RefreezePlan.pickIdle(entries, refreezeRunning: false, waiting: 2) == nil)
		let both = [E(n: 1, state: .thawed, needsRefreeze: true, tries: 0), E(n: 0, state: .thawed, needsRefreeze: true, tries: 0)]
		#expect(RefreezePlan.pickIdle(both, refreezeRunning: false, waiting: 0) == 0)
		let exhausted = [E(n: 0, state: .thawed, needsRefreeze: true, tries: 3), E(n: 1, state: .thawed, needsRefreeze: false, tries: 0)]
		#expect(RefreezePlan.pickIdle(exhausted, refreezeRunning: false, waiting: 0) == nil)
	}

	@Test func leftoverVMProcesses() {
		let ps = """
			  101 /Users/o/.cryo/bin/cryo bay start --listen :7477
			  102 /Users/o/.cryo/bin/cryo bay start
			  103 cryo bay freeze --capsule 0 --subnet 0
			  104 /Users/o/.cryo/bin/cryo bay status
			  105 /Users/o/.cryo/bin/cryo ssh L12
			  106 /Users/o/.cryo/bin/cryo ci github --repo a/b
			  108 /usr/bin/vim notes-about-cryo bay start
			  109 cryo bay
			"""
		let found = Leftovers.vmProcesses(ps: ps, selfPID: 102)
		#expect(found.map(\.pid) == [101, 103])
		#expect(found.first?.command == "/Users/o/.cryo/bin/cryo bay start --listen :7477")
		// Image commands: named by the code 6 watchdog, never stopped at start-up.
		let images = """
			  201 cryo image build --xcode --tag t
			  202 /Users/o/.cryo/bin/cryo bay image-use B
			  203 cryo image ls
			"""
		#expect(Leftovers.vmProcesses(ps: images, selfPID: 1).isEmpty)
		#expect(Leftovers.vmProcesses(ps: images, selfPID: 1, includeImageCommands: true).map(\.pid) == [201, 202])
		// Start-up: only cryo processes registered in this root (another CRYO_HOME's bay stays up).
		#expect(Leftovers.vmProcesses(ps: ps, selfPID: 102, home: [103]).map(\.pid) == [103])
		#expect(Leftovers.vmProcesses(ps: ps, selfPID: 102, home: []).isEmpty)
	}

	func scratch() throws -> BayPaths {
		let p = BayPaths(root: FileManager.default.temporaryDirectory.appending(path: "cryo-recovery-\(UUID().uuidString)", directoryHint: .isDirectory))
		try p.prepare()
		return p
	}

	/// Leftovers are those of this root only: a `run/<pid>` some process holds locked is live, one
	/// nobody holds is stale and goes. The lock is per open file, so this process can hold it too.
	@Test @MainActor func registeredProcessesAreTheLockedOnes() throws {
		let p = try scratch()
		defer { try? FileManager.default.removeItem(at: p.root) }
		try FileManager.default.createDirectory(at: p.run, withIntermediateDirectories: true)
		let live = p.run.appending(path: "4242")
		let stale = p.run.appending(path: "4343")
		let fd = try #require(Cleanup.tryLock(live))
		defer { close(fd) }
		FileManager.default.createFile(atPath: stale.path, contents: nil)
		#expect(Cleanup.registeredVMProcesses(p) == [4242])
		#expect(!FileManager.default.fileExists(atPath: stale.path))
		#expect(FileManager.default.fileExists(atPath: live.path))
		// This process's own registration isn't a leftover.
		try Cleanup.registerVMProcess(p)
		#expect(Cleanup.registeredVMProcesses(p) == [4242])
	}

	/// A second bay on the same root refuses while the first holds `bay.lock`, socket or not.
	@Test @MainActor func bayLockMakesASecondBayRefuse() throws {
		let p = try scratch()
		defer { try? FileManager.default.removeItem(at: p.root) }
		#expect(!Cleanup.bayRuns(p))
		let fd = try #require(Cleanup.tryLock(p.bayLock))
		#expect(Cleanup.bayRuns(p))
		#expect(throws: BayError.self) { try Cleanup.lockBay(p) }
		#expect(throws: BayError.self) { try Cleanup.refuseWhileBayRuns(p) }
		close(fd)
		// Not at once: a child another test is spawning right now shares the lock until its exec
		// drops the close-on-exec fd (and so may a child spawned while a probe holds the file).
		#expect(eventually { (try? Cleanup.refuseWhileBayRuns(p)) != nil })
	}

	@Test func interruptedRefreezeRepairs() {
		// Crash after moving 1 aside but before moving the new one in: put the old one back.
		// Capsule 0 is in place, so its stale .tmp-old-0 and every .tmp-refreeze go.
		let plan = Leftovers.refreezeRepairs(["0", ".tmp-old-0", ".tmp-old-1", ".tmp-refreeze-1", ".tmp-refreeze-0", ".DS_Store"])
		#expect(plan.restore == [1])
		#expect(plan.delete == [".tmp-old-0", ".tmp-refreeze-0", ".tmp-refreeze-1"])
		#expect(Leftovers.refreezeRepairs(["0", "1"]).restore.isEmpty)
		#expect(Leftovers.refreezeRepairs(["0", "1"]).delete.isEmpty)
		// Staging of a process still running is kept; a dead one's goes.
		let named = Leftovers.refreezeRepairs(["0", ".tmp-freeze-0.10", ".tmp-refreeze-1.20", ".tmp-use-1.30"], alive: { $0 == 30 })
		#expect(named.delete == [".tmp-freeze-0.10", ".tmp-refreeze-1.20"])
		#expect(Leftovers.stagingOwner(".tmp-use-1.30") == 30)
		#expect(Leftovers.stagingOwner(".tmp-old-1") == nil && Leftovers.stagingOwner(".tmp-use-1") == nil)
		#expect(Leftovers.staging("refreeze", 2, pid: 9) == ".tmp-refreeze-2.9")
	}

	@Test @MainActor func repairRefreezesOnDisk() throws {
		let p = try scratch()
		defer { try? FileManager.default.removeItem(at: p.root) }
		let fm = FileManager.default
		func dir(_ name: String) throws { try fm.createDirectory(at: p.capsules.appending(path: name), withIntermediateDirectories: true) }
		try dir(".tmp-old-1")
		try "old".write(to: p.capsules.appending(path: ".tmp-old-1/manifest.json"), atomically: true, encoding: .utf8)
		try dir("0")
		let mine = Leftovers.staging("use", 0)  // this test process: alive
		for name in [".tmp-old-0", ".tmp-refreeze-0", ".tmp-use-1.\(Int32.max)", mine] { try dir(name) }
		Cleanup.repairRefreezes(p)
		let left = Set(try fm.contentsOfDirectory(atPath: p.capsules.path))
		#expect(left == ["0", "1", mine])
		#expect(try String(contentsOf: p.capsule(1).manifest, encoding: .utf8) == "old")
	}

	@Test @MainActor func removeDeadBuildsOnDisk() throws {
		let p = try scratch()
		defer { try? FileManager.default.removeItem(at: p.root) }
		let fm = FileManager.default
		let names = [".build-\(getpid())", ".build-\(Int32.max)", "57fdf55b5925500d"]
		for n in names { try fm.createDirectory(at: p.images.appending(path: n), withIntermediateDirectories: true) }
		Cleanup.removeDeadBuilds(p)
		#expect(Set(try fm.contentsOfDirectory(atPath: p.images.path)) == [".build-\(getpid())", "57fdf55b5925500d"])
	}

	@Test func vmServicesAreVirtualizationsXPCProcesses() {
		let ps = """
			  501 /System/Library/Frameworks/Virtualization.framework/Versions/A/XPCServices/com.apple.Virtualization.VirtualMachine.xpc/Contents/MacOS/com.apple.Virtualization.VirtualMachine
			  502 /System/Library/PrivateFrameworks/AppleVirtualPlatform.framework/Versions/A/PlugIns/com.apple.AppleVirtualPlatform.Identity.Virtio.vzplugin/Contents/MacOS/x
			  503 cryo bay start
			"""
		#expect(Leftovers.vmServices(ps: ps) == [501])
	}

	@Test func deadBuildsAreOnlyThoseWhoseProcessIsGone() {
		let names = [".build-100", ".build-200", ".build-x", "57fdf55b5925500d", ".tmp-use-0"]
		#expect(Leftovers.deadBuilds(names, alive: { $0 == 200 }) == [".build-100", ".build-x"])
		#expect(Leftovers.processAlive(getpid()))
	}

	/// Only a fresh process recovers taken subnets after InternetSharing restarts.
	@Test func restartOnlyWhenEveryCapsuleIsStuckOnItsSubnet() {
		#expect(RestartPolicy.shouldRestart(lastFailures: [0: .subnet, 1: .subnet], capsules: 2, liveVMs: 0, leases: 0))
		#expect(!RestartPolicy.shouldRestart(lastFailures: [0: .subnet], capsules: 2, liveVMs: 0, leases: 0))
		#expect(!RestartPolicy.shouldRestart(lastFailures: [0: .subnet, 1: .other], capsules: 2, liveVMs: 0, leases: 0))
		#expect(!RestartPolicy.shouldRestart(lastFailures: [0: .subnet, 1: .subnet], capsules: 2, liveVMs: 1, leases: 0))
		#expect(!RestartPolicy.shouldRestart(lastFailures: [0: .subnet, 1: .subnet], capsules: 2, liveVMs: 0, leases: 1))
		#expect(!RestartPolicy.shouldRestart(lastFailures: [:], capsules: 0, liveVMs: 0, leases: 0))
	}

	@Test func subnetAlertNamesTheCapsulesAndTheCommand() {
		#expect(SubnetAlert.text(stuck: []) == nil)
		let t = SubnetAlert.text(stuck: [1, 0])
		#expect(t?.hasPrefix("capsule 0, 1: vmnet subnet taken") == true)
		#expect(t?.contains("`sudo killall InternetSharing`") == true)
	}
}

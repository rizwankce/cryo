import CryoHTTP
import Darwin
import Foundation
import Virtualization

// MARK: - Pure recovery decisions (unit-tested without VMs)

/// What a failed refill means for recovery.
enum FailureKind: Equatable {
	/// `VZErrorVirtualMachineLimitExceeded` (code 6): the host refused one more VM.
	case vmLimit
	/// vmnet couldn't create the capsule's subnet: a crashed process left it claimed by
	/// InternetSharing, which never lets go on its own.
	case subnet
	case other

	static func of(_ error: Error) -> FailureKind {
		if error is VMNetUnavailable { return .subnet }
		let e = error as NSError
		if e.domain == VZErrorDomain && e.code == VZError.Code.virtualMachineLimitExceeded.rawValue { return .vmLimit }
		return .other
	}
}

/// How long a capsule waits before its next refill after `failures` failures in a row. The first
/// retries are quick (a one-off hiccup); then the capsule is `broken` and keeps retrying with
/// backoff for as long as the bay runs. A taken subnet is checked every minute; InternetSharing
/// doesn't free it on its own, so RestartPolicy restarts the bay when every capsule is stuck.
enum RetryPolicy {
	/// Failures before the capsule counts as broken (and `start()` stops waiting for it).
	static let quickTries = 3

	static func delayS(afterFailures n: Int, kind: FailureKind) -> Int {
		if n < quickTries { return 5 }
		let backoff = 30 << min(n - quickTries, 5)  // 30, 60, 120, ... capped below
		return min(backoff, kind == .subnet ? 60 : 600)
	}
}

/// vmnet in a process doesn't reconnect once InternetSharing restarts: after `sudo killall
/// InternetSharing` the same bay kept failing with 1001 (72 tries) while a new process got both
/// subnets at once. So when every capsule is broken on a taken subnet and nothing runs, the
/// bay exits and launchd starts a fresh one (60 s throttle).
enum RestartPolicy {
	static let exitCode: Int32 = 75  // EX_TEMPFAIL: not a clean stop, so KeepAlive restarts it

	static func shouldRestart(lastFailures: [Int: FailureKind], capsules: Int, liveVMs: Int, leases: Int) -> Bool {
		capsules > 0 && lastFailures.count == capsules && lastFailures.values.allSatisfy { $0 == .subnet }
			&& liveVMs == 0 && leases == 0
	}
}

/// What `status` and `doctor` tell a person when capsules are stuck on taken subnets.
enum SubnetAlert {
	static let command = "sudo killall InternetSharing"

	/// nil unless some capsule's last refill failed on its subnet.
	static func text(stuck: [Int]) -> String? {
		guard !stuck.isEmpty else { return nil }
		let which = stuck.sorted().map(String.init).joined(separator: ", ")
		return
			"capsule \(which): vmnet subnet taken (a cryo process was killed while its VMs ran); run `\(command)` on this Mac (the bay picks the subnets up within a minute), or reboot"
	}
}

/// The code 6 watchdog: what a VM-limit refusal means.
enum VMLimitVerdict: Equatable {
	/// Another process runs VMs (a stray `cryo bay` command): stop it and retry.
	case otherProcesses
	/// This bay already runs as many VMs as the host allows: a bookkeeping bug, not the host.
	case ownVMs
	/// Fewer than the limit run, but only for the first quick tries: the host frees a stopped VM's
	/// place a moment after `stop()` returns. For example, two capsules
	/// stopped at once, the next refill got code 6 with 1 VM running and worked 5 s later.
	case settling
	/// Fewer than the limit run anywhere, yet the host refuses: its VM count leaked. Only a host
	/// reboot clears it.
	case leak

	static let hostLimit = 2

	static func of(liveVMs: Int, otherProcesses: Int, failures: Int = RetryPolicy.quickTries) -> VMLimitVerdict {
		if otherProcesses > 0 { return .otherProcesses }
		if liveVMs >= hostLimit { return .ownVMs }
		return failures < RetryPolicy.quickTries ? .settling : .leak
	}
}

/// When to refreeze a capsule whose saved state couldn't be used (cold boot fallback).
/// One refreeze at a time, so the other capsule keeps serving; at most `maxTries` in a row without
/// a successful restore, so a refreeze that doesn't fix it can't loop.
enum RefreezePlan {
	static let maxTries = 3

	/// A forced fallback is a test knob, not a stale state: refreezing wouldn't change it.
	static func needed(fallbackReason: String?) -> Bool {
		guard let r = fallbackReason else { return false }
		return r != forcedReason
	}

	static let forcedReason = "CRYO_FORCE_FALLBACK set"

	/// Warm-up platforms a refreeze bakes in: what the manifest recorded (`[]` means none). Older
	/// manifests didn't record it; capsules of an Xcode image (tag `xcode-...`) were all frozen
	/// with the iOS warm-up, so they get it again.
	static func warmUp(recorded: [String]?, imageTag: String) -> [String]? {
		if let recorded { return recorded.isEmpty ? nil : recorded }
		return imageTag.hasPrefix("xcode-") ? ["ios"] : nil
	}

	struct Entry: Equatable {
		var n: Int
		var state: Capsule.State
		var needsRefreeze: Bool
		var tries: Int
	}

	static func eligible(_ e: Entry) -> Bool { e.needsRefreeze && e.tries < maxTries }

	/// After a lease on a capsule ends: refreeze it now instead of refilling it? Not while requests
	/// wait: the cold boot fallback serves them faster than a refreeze (~2 min) would.
	static func afterLease(_ e: Entry, refreezeRunning: Bool, waiting: Int) -> Bool {
		!refreezeRunning && waiting == 0 && eligible(e)
	}

	/// An idle (thawed, unleased) capsule to take out of service for its refreeze now, if any.
	/// Never while a refreeze runs or requests wait.
	static func pickIdle(_ entries: [Entry], refreezeRunning: Bool, waiting: Int) -> Int? {
		guard !refreezeRunning, waiting == 0 else { return nil }
		return entries.filter { $0.state == .thawed && eligible($0) }.map(\.n).min()
	}
}

/// Start-up cleanup (docs/spec/bay.md "Start-up" step 2): what counts as a leftover VM process.
enum Leftovers {
	struct Process: Equatable {
		var pid: Int32
		var command: String
	}

	/// `cryo bay` subcommands that run VMs. Other `cryo` processes (lease, ssh, mcp, ci) never do.
	static let vmSubcommands: Set<String> = ["start", "freeze", "thaw-test", "lease-test"]

	/// Image commands also run VMs (the build VM, `use`'s freezes). Start-up cleanup leaves them alone
	/// (stopping one throws away a ~16 min build); the code 6 watchdog names them.
	static let imageVMCommands: Set<String> = ["image build", "image use", "bay image-build", "bay image-use"]

	/// Parses `ps -x -o pid=,args=` and keeps this user's other processes that run VMs:
	/// `cryo bay <vm subcommand>`, plus image commands if asked.
	/// With `home`, only the `cryo` processes whose pid is in it (those registered in this bay's
	/// root, `Cleanup.registerVMProcess`): a bay with another `CRYO_HOME` is not this one's leftover.
	static func vmProcesses(ps: String, selfPID: Int32, includeImageCommands: Bool = false, home: Set<Int32>? = nil) -> [Process] {
		ps.split(separator: "\n").compactMap { line in
			let parts = line.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
			guard parts.count >= 2, let pid = Int32(parts[0]), pid != selfPID else { return nil }
			let args = Array(parts.dropFirst())
			let exe = (args[0] as NSString).lastPathComponent
			let ours = home.map { $0.contains(pid) } ?? true
			let runsVMs =
				(ours && exe == "cryo" && args.count >= 3 && args[1] == "bay" && vmSubcommands.contains(args[2]))
				|| (ours && includeImageCommands && exe == "cryo" && args.count >= 3 && imageVMCommands.contains("\(args[1]) \(args[2])"))
			return runsVMs ? Process(pid: pid, command: args.joined(separator: " ")) : nil
		}
	}

	/// `images/.build-<pid>` folders whose build process is gone (a Ctrl-C'd build leaves ~26 GB; its
	/// signal handler exits before the clean-up). A live build's folder is kept.
	static func deadBuilds(_ names: [String], alive: (Int32) -> Bool) -> [String] {
		names.filter { name in
			guard name.hasPrefix(".build-") else { return false }
			guard let pid = Int32(name.dropFirst(".build-".count)) else { return true }
			return !alive(pid)
		}.sorted()
	}

	static func processAlive(_ pid: Int32) -> Bool { kill(pid, 0) == 0 || errno == EPERM }

	/// Virtualization's per-VM XPC services (`com.apple.Virtualization.VirtualMachine`). They outlive
	/// the process that ran the VM by a few seconds while it tears down, and count against the limit.
	static func vmServices(ps: String) -> [Int32] {
		ps.split(separator: "\n").compactMap { line in
			let parts = line.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
			guard parts.count == 2, let pid = Int32(parts[0]),
				parts[1].contains("com.apple.Virtualization.VirtualMachine.xpc/")
			else { return nil }
			return pid
		}
	}

	/// `.tmp-<kind>-N.<pid>`: where process `pid` freezes capsule N (`freeze`, `refreeze`, `use`)
	/// before swapping it in. The pid says whose it is, like `images/.build-<pid>`.
	static func staging(_ kind: String, _ n: Int, pid: Int32 = getpid()) -> String { ".tmp-\(kind)-\(n).\(pid)" }

	/// The pid in a staging name, nil for names without one (`.tmp-old-N`, older staging names).
	static func stagingOwner(_ name: String) -> Int32? {
		guard name.hasPrefix(".tmp-"), let dot = name.lastIndex(of: "."), dot != name.startIndex else { return nil }
		return Int32(name[name.index(after: dot)...])
	}

	/// Freezes work in a staging directory and swap the old capsule out to `capsules/.tmp-old-N`.
	/// Given the names in `capsules/`, which leftovers to move back (a crash between the two renames
	/// left `N` missing) and which to delete. Staging of a process still running (an `image use`
	/// while the bay starts) is kept.
	static func refreezeRepairs(_ names: [String], alive: (Int32) -> Bool = processAlive) -> (restore: [Int], delete: [String]) {
		let present = Set(names)
		var restore: [Int] = []
		var delete: [String] = []
		for name in names.sorted() where name.hasPrefix(".tmp-") {
			if name.hasPrefix(".tmp-old-"), let n = Int(name.dropFirst(".tmp-old-".count)), !present.contains(String(n)) {
				restore.append(n)
			} else if let owner = stagingOwner(name), alive(owner) {
				continue
			} else {
				delete.append(name)
			}
		}
		return (restore, delete)
	}
}

// MARK: - Start-up cleanup (host side)

/// vmnet refused the capsule's subnet. Typed so recovery can tell it from other failures.
struct VMNetUnavailable: Error, CustomStringConvertible {
	let subnet: Int
	let status: UInt32
	var description: String {
		"vmnet network for 10.77.\(subnet).1/24: \(status). If a cryo process was killed while its VM ran, InternetSharing still holds the subnet until it idles out (minutes); sudo killall InternetSharing frees it now"
	}
}

@MainActor
enum Cleanup {
	/// Running VMs this process created (the code 6 watchdog's count).
	static var liveVMs: Int {
		CapsuleVM.live.compactMap(\.vm).filter { $0.state != .stopped && $0.state != .error }.count
	}

	/// A bay that still answers on the socket is serving leases; never stop it.
	static func bayAnswers(_ paths: BayPaths) -> Bool {
		guard let s = try? Socket.connectUnix(path: paths.socket.path) else { return false }
		s.close()
		return true
	}

	// MARK: Who runs in this bay's root

	/// Lock files this process holds for its whole life (the kernel drops them when it exits).
	private static var held: [String: Int32] = [:]

	/// Opens `url` with an exclusive flock; nil (and `errno` EWOULDBLOCK) if another open file holds
	/// it. Close-on-exec, so a child (ssh, a sudo prompt) never keeps the lock past its parent.
	static func tryLock(_ url: URL, create: Bool = true) -> Int32? {
		let fd = open(url.path, O_RDWR | O_EXLOCK | O_NONBLOCK | O_CLOEXEC | (create ? O_CREAT : 0), 0o644)
		return fd >= 0 ? fd : nil
	}

	private static func hold(_ url: URL) -> Bool {
		if held[url.path] != nil { return true }
		guard let fd = tryLock(url) else { return false }
		held[url.path] = fd
		return true
	}

	/// The bay (`start`, `lease-test`) locks `bay.lock` for its life, so a second bay on the same root
	/// refuses even before the first has bound its socket.
	static func lockBay(_ paths: BayPaths) throws {
		guard hold(paths.bayLock) else {
			throw BayError("another bay is starting or running in \(paths.root.path) (\(paths.bayLock.path) is locked)")
		}
	}

	/// Another process's bay holds `bay.lock`, or the socket answers.
	static func bayRuns(_ paths: BayPaths) -> Bool {
		if bayAnswers(paths) { return true }
		if held[paths.bayLock.path] != nil { return false }
		guard let fd = tryLock(paths.bayLock, create: false) else { return errno == EWOULDBLOCK }
		close(fd)
		return false
	}

	/// `cryo bay freeze` and `cryo image use` don't run beside a bay: it holds the capsules' files
	/// and VMs (Apple allows 2 per Mac).
	static func refuseWhileBayRuns(_ paths: BayPaths) throws {
		guard bayRuns(paths) else { return }
		throw BayError(
			"""
			the bay is running (\(paths.socket.path) answers or \(paths.bayLock.path) is locked). Stop it first; that ends its leases:
			  launchctl bootout gui/\(getuid())/\(BayInstall.agentLabel)   (or Ctrl-C a foreground cryo bay start)
			""")
	}

	/// A `cryo bay` command that runs VMs (`freeze`, `thaw-test`) locks `run/<pid>` for its life, so
	/// start-up cleanup stops leftovers of this root only.
	static func registerVMProcess(_ paths: BayPaths) throws {
		try FileManager.default.createDirectory(at: paths.run, withIntermediateDirectories: true)
		let url = paths.run.appending(path: String(getpid()))
		guard hold(url) else { throw BayError("can't lock \(url.path): \(String(cString: strerror(errno)))") }
	}

	/// Pids whose `run/<pid>` another process has locked: live VM processes of this root. A file
	/// nobody holds was left by a process that exited, and goes (a reused pid never took its lock).
	static func registeredVMProcesses(_ paths: BayPaths) -> Set<Int32> {
		var pids: Set<Int32> = []
		for name in (try? FileManager.default.contentsOfDirectory(atPath: paths.run.path)) ?? [] {
			guard let pid = Int32(name) else { continue }
			let url = paths.run.appending(path: name)
			if held[url.path] != nil { continue }
			if let fd = tryLock(url, create: false) {
				unlink(url.path)
				close(fd)
			} else if errno == EWOULDBLOCK {
				pids.insert(pid)
			}
		}
		return pids
	}

	/// This user's other VM processes; with `home`, only the `cryo` ones registered in that root.
	static func otherVMProcesses(includeImageCommands: Bool = false, home: BayPaths? = nil) async -> [Leftovers.Process] {
		let registered = home.map(registeredVMProcesses)
		let r = await runProcess("/bin/ps", ["-x", "-o", "pid=,args="])
		return r.status == 0
			? Leftovers.vmProcesses(ps: r.out, selfPID: getpid(), includeImageCommands: includeImageCommands, home: registered) : []
	}

	/// SIGTERM lets each process's exit handler stop its VMs, which frees their vmnet subnets;
	/// SIGKILL only for one still alive after 15 s (its subnet then stays taken until InternetSharing is killed).
	static func stop(_ procs: [Leftovers.Process]) async {
		guard !procs.isEmpty else { return }
		let services = Leftovers.vmServices(ps: await runProcess("/bin/ps", ["-x", "-o", "pid=,args="]).out)
		for p in procs {
			BayTrace.note("stopping leftover VM process \(p.pid): \(p.command)")
			kill(p.pid, SIGTERM)
		}
		let deadline = Date().addingTimeInterval(15)
		var alive = procs
		while !alive.isEmpty && Date() < deadline {
			try? await Task.sleep(for: .milliseconds(200))
			alive = alive.filter { kill($0.pid, 0) == 0 }
		}
		for p in alive {
			BayTrace.note("leftover VM process \(p.pid) ignored SIGTERM; killing it (its subnet stays taken until `sudo killall InternetSharing`)")
			kill(p.pid, SIGKILL)
		}
		// The VM services tear down after their client exits; restoring before they're gone hit
		// code 6 and a capsule restore failing with "invalid argument". Services of other
		// apps' VMs never exit, so the wait is capped.
		var waiting = services
		let servicesDeadline = Date().addingTimeInterval(10)
		while !waiting.isEmpty && Date() < servicesDeadline {
			try? await Task.sleep(for: .milliseconds(200))
			waiting = waiting.filter { kill($0, 0) == 0 }
		}
		if services.count > waiting.count {
			BayTrace.note("\(services.count - waiting.count) leftover VM service(s) exited")
		}
	}

	/// Moves back a capsule a crash left swapped out mid-refreeze, and deletes refreeze leftovers.
	static func repairRefreezes(_ paths: BayPaths) {
		let fm = FileManager.default
		let names = (try? fm.contentsOfDirectory(atPath: paths.capsules.path)) ?? []
		let plan = Leftovers.refreezeRepairs(names)
		for n in plan.restore {
			BayTrace.note("capsule \(n): restoring the copy an interrupted refreeze swapped out")
			try? fm.moveItem(at: paths.capsules.appending(path: ".tmp-old-\(n)"), to: paths.capsule(n).dir)
		}
		for name in plan.delete { try? fm.removeItem(at: paths.capsules.appending(path: name)) }
	}

	/// Deletes what interrupted image builds left in `images/`.
	static func removeDeadBuilds(_ paths: BayPaths) {
		let fm = FileManager.default
		for name in Leftovers.deadBuilds((try? fm.contentsOfDirectory(atPath: paths.images.path)) ?? [], alive: Leftovers.processAlive) {
			BayTrace.note("deleting \(name), left by an interrupted image build")
			try? fm.removeItem(at: paths.images.appending(path: name))
		}
	}

	/// Step 2 of the start-up (vmnet subnets are retried by the refill loop until they free up).
	/// Only leftovers of this root are stopped (`run/<pid>`): a bay with another
	/// `CRYO_HOME` is left alone, and one of this root still starting makes this one refuse.
	static func atStart(_ paths: BayPaths) async throws {
		if bayAnswers(paths) { throw BayError("another bay is running (\(paths.socket.path) answers)") }
		try lockBay(paths)
		removeDeadBuilds(paths)
		await stop(await otherVMProcesses(home: paths))
		repairRefreezes(paths)
	}
}

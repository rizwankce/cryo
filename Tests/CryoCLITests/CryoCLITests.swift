import CryoAPI
import CryoClient
import CryoHTTP
import FakeBay
import Testing

@testable import CryoCLI

#if canImport(FoundationEssentials)
	import FoundationEssentials
#else
	import Foundation
#endif

/// A temp HOME with a short path, a context wired to a FakeBay, and captured output.
final class Env: @unchecked Sendable {
	let home: String
	let bay: FakeBay
	var stdout = ""
	var stderr = ""
	var execs: [[String]] = []
	var input: [String] = []
	var stdinIsTTY = false
	var cwd = "/work/proj"
	var stdinFD: Int32 = 0
	var stdoutFD: Int32 = 1

	init(capacity: Int = 2, startBay: Bool = true) throws {
		var template = Array("/tmp/cryo-home-XXXXXX".utf8CString)
		guard mkdtemp(&template) != nil else { throw FileError(description: "mkdtemp") }
		home = String(decoding: template.dropLast().map { UInt8(bitPattern: $0) }, as: UTF8.self)
		bay = FakeBay(capacity: capacity)
		if startBay { try bay.start() }
	}

	deinit {
		bay.stop()
		try? FileManager.default.removeItem(atPath: home)
	}

	func run(_ args: String...) -> Int32 { runArgs(args) }

	func runArgs(_ args: [String], socket: String? = nil) -> Int32 {
		let ctx = CLIContext(
			home: home, cwd: cwd,
			target: CryoTarget(endpoint: .unix(path: socket ?? bay.socketPath)),
			out: { self.stdout += $0 }, err: { self.stderr += $0 },
			readLine: { self.input.isEmpty ? nil : self.input.removeFirst() },
			stdinIsTTY: stdinIsTTY, stdinFD: stdinFD, stdoutFD: stdoutFD,
			exec: {
				self.execs.append($0)
				return 0
			})
		return CryoCLI.run(args, ctx)
	}

	func path(_ rel: String) -> String { home + "/" + rel }
	func read(_ rel: String) -> String? { readTextFile(path(rel)) }
}

@Suite struct LeaseTests {
	@Test func writesKeyAndConfigAndPrintsReady() throws {
		let e = try Env()
		#expect(e.run("lease") == 0)
		#expect(e.stdout == "L1 ready: ssh cryo-L1\n")
		#expect(fileMode(e.path(".cryo/keys/L1")) == 0o600)
		#expect(fileMode(e.path(".cryo/keys")) == 0o700)
		#expect(fileMode(e.path(".cryo/ssh_config")) == 0o600)
		#expect(e.read(".cryo/keys/L1")?.contains("fake-key-L1") == true)
		let cfg = try #require(e.read(".cryo/ssh_config"))
		#expect(cfg.hasPrefix("# cryo lease L1\nHost cryo-L1\n"))
		#expect(
			cfg.hasSuffix("  UserKnownHostsFile ~/.cryo/known_hosts/L1\n  GlobalKnownHostsFile /dev/null\n  StrictHostKeyChecking yes\n# end cryo lease L1\n"))
		// The host key is pinned in the lease's own known_hosts file, under the HostKeyAlias.
		#expect(e.read(".cryo/known_hosts/L1") == "cryo-L1 ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIFakeHostKeyL1\n")
		#expect(fileMode(e.path(".cryo/known_hosts")) == 0o700)
		#expect(!pathExists(e.path(".ssh/known_hosts")))
		#expect(e.stderr.contains("cryo setup"))
	}

	@Test func secondLeaseAddsBlockAndReplaceIsIdempotent() throws {
		let e = try Env()
		_ = e.run("lease")
		_ = e.run("lease")
		let local = LocalState(home: e.home)
		let l = try CryoClient(target: CryoTarget(endpoint: .unix(path: e.bay.socketPath))).lease("L1")
		try local.saveLease(l)
		try local.saveLease(l)
		let cfg = try #require(e.read(".cryo/ssh_config"))
		#expect(blockIDs(cfg).sorted() == ["L1", "L2"])
	}

	@Test func leaseIsReleasedWhenItsKeyCannotBeSaved() throws {
		let e = try Env()
		try makeDirs(e.path(".cryo"), mode: 0o700)
		try writeAtomically(e.path(".cryo/keys"), "not a directory")
		#expect(e.run("lease") == 1)
		#expect(e.stderr.contains("cryo lease: cannot write"))
		#expect(e.bay.releases == [.init(id: "L1", saveCache: false)])
		#expect(e.bay.leases.isEmpty)
		#expect(blockIDs(e.read(".cryo/ssh_config") ?? "").isEmpty)
	}

	@Test func keyFileWiderModeIsTightened() throws {
		let e = try Env()
		try makeDirs(e.path(".cryo/keys"), mode: 0o700)
		let fd = open(e.path(".cryo/keys/L1"), O_WRONLY | O_CREAT, 0o644)
		close(fd)
		chmod(e.path(".cryo/keys/L1"), 0o644)
		#expect(e.run("lease") == 0)
		#expect(fileMode(e.path(".cryo/keys/L1")) == 0o600)
	}

	@Test func noHintWhenIncluded() throws {
		let e = try Env()
		#expect(e.run("setup", "--yes") == 0)
		e.stdout = ""
		#expect(e.run("lease") == 0)
		#expect(e.stderr.isEmpty)
	}

	@Test func jsonOutput() throws {
		let e = try Env()
		#expect(e.run("lease", "--json", "--name", "x", "--cache", "app") == 0)
		let l = try CryoJSON.decoder().decode(Lease.self, from: Data(e.stdout.utf8))
		#expect(l.id == "L1")
		#expect(l.name == "x")
		#expect(l.cache == "app")
	}

	@Test func folderMadeAbsoluteAndIdleSent() throws {
		let e = try Env()
		#expect(e.run("lease", "--folder", "./repo/../other", "--idle=2h") == 0)
		let r = try #require(e.bay.lastLeaseRequest)
		#expect(r.folder == "/work/proj/other")
		#expect(r.idleS == 7200)
		#expect(r.waitS == nil)  // not given: the bay's configured default applies
		_ = e.run("lease", "--wait", "5", "--idle", "7d")
		#expect(e.bay.lastLeaseRequest?.idleS == 7200)  // bad --idle: no request sent
		#expect(absolutePath("./repo/../other", cwd: "/work/proj") == "/work/proj/other")
		#expect(absolutePath("/abs/x", cwd: "/work") == "/abs/x")
	}

	@Test func waitAndIdleAreSentOnlyWhenGiven() throws {
		let e = try Env(capacity: 3)
		#expect(e.run("lease") == 0)
		let r = try #require(e.bay.lastLeaseRequest)
		#expect(r.waitS == nil && r.idleS == nil)
		#expect(e.bay.leases.last?.idleS == 3600)  // the bay's default
		#expect(e.run("lease", "--wait", "5") == 0)
		#expect(e.bay.lastLeaseRequest?.waitS == 5)
		#expect(e.bay.lastLeaseRequest?.idleS == nil)
		#expect(e.run("lease", "--idle", "90s") == 0)
		#expect(e.bay.lastLeaseRequest?.waitS == nil)
		#expect(e.bay.lastLeaseRequest?.idleS == 90)
	}

	@Test func idleParsing() {
		#expect(parseIdle("90s") == 90)
		#expect(parseIdle("60m") == 3600)
		#expect(parseIdle("2h") == 7200)
		#expect(parseIdle("45") == 2700)
		#expect(parseIdle("48h") == 86400)
		#expect(parseIdle("99999999999999999h") == 86400)
		for bad in ["", "m", "0", "0m", "-5m", "1.5h", "abc", "5d", "1 h"] { #expect(parseIdle(bad) == nil, "\(bad)") }
	}

	@Test func badIdleAndWaitAreUsageErrors() throws {
		let e = try Env()
		#expect(e.run("lease", "--idle", "soon") == 2)
		#expect(e.stderr.contains("--idle"))
		#expect(e.run("lease", "--wait", "-1") == 2)
		#expect(e.run("lease", "--bogus") == 2)
		#expect(e.run("lease", "--wait") == 2)
		#expect(e.bay.leases.isEmpty)
	}

	@Test func waitZeroWithNoCapacity() throws {
		let e = try Env(capacity: 1)
		#expect(e.run("lease") == 0)
		e.stderr = ""
		#expect(e.run("lease", "--wait", "0") == 1)
		#expect(e.stderr == "cryo lease: no free capsule\n")
		#expect(e.bay.leases.count == 1)
	}

	@Test func noBayIsACleanError() throws {
		let e = try Env(startBay: false)
		#expect(e.runArgs(["lease"], socket: "/tmp/cryo-none.sock") == 1)
		#expect(e.stderr.contains("no bay at unix:///tmp/cryo-none.sock"))
	}

	@Test func upgradeRequired() throws {
		let e = try Env()
		e.bay.requireMinimumClientVersion = 99
		#expect(e.run("status") == 1)
		#expect(e.stderr == "cryo status: this cryo is too old for the bay; update it\n")
	}

	@Test func leaseHelp() throws {
		let e = try Env()
		#expect(e.run("lease", "--help") == 0)
		#expect(e.stdout.contains("usage: cryo lease"))
		#expect(e.run("help", "release") == 0)
	}
}

@Suite struct ReleaseLsStatusTests {
	@Test func releaseRemovesLocalStateAndRecordsSaveCache() throws {
		let e = try Env()
		_ = e.run("lease")
		_ = e.run("lease")
		e.stdout = ""
		#expect(e.run("release", "L1", "--save-cache") == 0)
		#expect(e.stdout == "L1 released\n")
		#expect(e.bay.releases == [.init(id: "L1", saveCache: true)])
		#expect(!pathExists(e.path(".cryo/keys/L1")))
		#expect(pathExists(e.path(".cryo/keys/L2")))
		#expect(!pathExists(e.path(".cryo/known_hosts/L1")))
		#expect(pathExists(e.path(".cryo/known_hosts/L2")))
		#expect(blockIDs(e.read(".cryo/ssh_config") ?? "") == ["L2"])
		#expect(e.run("release", "L2") == 0)
		#expect(e.bay.releases.last == .init(id: "L2", saveCache: false))
	}

	@Test func releaseNotFoundStillCleansLocally() throws {
		let e = try Env()
		_ = e.run("lease")
		_ = e.run("release", "L1")
		// Re-create stale local state for a lease the bay no longer has.
		let l = Lease(
			id: "L1", capsule: 0, state: "leased", createdAt: Date(), renewBy: Date(), expiresAt: Date(),
			ssh: SSHInfo(user: "cryo", host: "cryo-L1", key: "k", config: "Host cryo-L1\n  User cryo"))
		try LocalState(home: e.home).saveLease(l)
		e.stderr = ""
		#expect(e.run("release", "L1") == 1)
		#expect(e.stderr.contains("not_found"))
		#expect(!pathExists(e.path(".cryo/keys/L1")))
		#expect(blockIDs(e.read(".cryo/ssh_config") ?? "").isEmpty)
	}

	@Test func releaseNeedsID() throws {
		let e = try Env()
		#expect(e.run("release") == 2)
	}

	@Test func lsTableAndPruning() throws {
		let e = try Env()
		#expect(e.run("ls") == 0)
		#expect(e.stdout == "no leases\n")
		_ = e.run("lease", "--name", "fix-login", "--cache", "app")
		_ = e.run("lease")
		// A stale local lease (the bay lost it) and an unrelated file in ~/.ssh stay/prune correctly.
		let stale = Lease(
			id: "L77", capsule: 0, state: "leased", createdAt: Date(), renewBy: Date(), expiresAt: Date(),
			ssh: SSHInfo(user: "cryo", host: "cryo-L77", key: "k", config: "Host cryo-L77"))
		try LocalState(home: e.home).saveLease(stale, bay: CryoTarget(endpoint: .unix(path: e.bay.socketPath)))
		age(e.path(".cryo/keys/L77"), e.path(".cryo/lease-bays/L77"))
		try writeAtomically(e.path(".ssh-other"), "keep")
		e.stdout = ""
		#expect(e.run("ls") == 0)
		let rows = e.stdout.split(separator: "\n").map(String.init)
		#expect(rows.count == 3)
		#expect(rows[0].hasPrefix("ID"))
		#expect(rows[0].contains("RENEW BY"))
		#expect(rows[1].hasPrefix("L1"))
		#expect(rows[1].contains("fix-login"))
		#expect(rows[1].contains("app"))
		#expect(rows[1].contains("in 60m"))  // renew_by is created_at + idle_s
		#expect(!pathExists(e.path(".cryo/keys/L77")))
		#expect(blockIDs(e.read(".cryo/ssh_config") ?? "") == ["L1", "L2"])
		#expect(pathExists(e.path(".ssh-other")))
		e.stdout = ""
		#expect(e.run("ls", "--json") == 0)
		let ls = try CryoJSON.decoder().decode([Lease].self, from: Data(e.stdout.utf8))
		#expect(ls.map(\.id) == ["L1", "L2"])
	}

	/// Local state holds every bay's leases; `ls` on one bay must not forget another's (or a lease
	/// `cryo lease` saved after the bay made its list).
	@Test func lsForgetsOnlyOldLeasesOfTheBayItListed() throws {
		let e = try Env()
		let other = FakeBay()
		try other.start()
		defer { other.stop() }
		#expect(e.run("lease") == 0)  // L1 on e.bay
		#expect(e.read(".cryo/lease-bays/L1") == "unix://\(e.bay.socketPath)\n")
		let local = LocalState(home: e.home)
		let lease = { (id: String) in
			Lease(
				id: id, capsule: 0, state: "leased", createdAt: Date(), renewBy: Date(), expiresAt: Date(),
				ssh: SSHInfo(user: "cryo", host: "cryo-\(id)", key: "k", config: "Host cryo-\(id)"))
		}
		try local.saveLease(lease("L50"))  // no record: the default local bay's
		try local.saveLease(lease("L60"), bay: CryoTarget(endpoint: .unix(path: other.socketPath)))
		try local.saveLease(lease("L70"), bay: CryoTarget(endpoint: .unix(path: e.bay.socketPath)))  // just saved
		age(e.path(".cryo/keys/L1"), e.path(".cryo/lease-bays/L1"), e.path(".cryo/known_hosts/L1"))
		age(e.path(".cryo/keys/L50"), e.path(".cryo/keys/L60"), e.path(".cryo/lease-bays/L60"))

		// The other bay lists nothing: only its own old lease goes.
		#expect(e.runArgs(["ls"], socket: other.socketPath) == 0)
		#expect(local.localIDs() == ["L1", "L50", "L70"])
		// This bay lists L1: L70 is too new to forget, L50 belongs to the default bay.
		#expect(e.run("ls") == 0)
		#expect(local.localIDs() == ["L1", "L50", "L70"])
		age(e.path(".cryo/keys/L70"), e.path(".cryo/lease-bays/L70"))
		#expect(e.run("ls") == 0)
		#expect(local.localIDs() == ["L1", "L50"])
		// The default bay forgets L50.
		let home = CryoTarget(endpoint: .unix(path: e.path(".cryo/bay.sock")))
		#expect(local.bay(of: "L50") == home.display)
		#expect(local.forgetLeases(except: [], on: home) == ["L50"])
		#expect(blockIDs(e.read(".cryo/ssh_config") ?? "") == ["L1"])
	}

	@Test func statusOutput() throws {
		let e = try Env()
		_ = e.run("lease")
		e.stdout = ""
		#expect(e.run("status") == 0)
		#expect(e.stdout.contains("bay: version fake, image fake-image, doctor ok\nhealth: bay up "))
		#expect(e.stdout.contains(", host up 3d, disk 120 GB free, thermal nominal\n"))
		#expect(e.stdout.contains("leases: 1 served, 0 failed, 0 expired (last 812 ms); refills: 0 ok, 0 failed\n"))
		#expect(e.stdout.contains("capsule 0  leased"))
		#expect(e.stdout.contains("L1"))
		#expect(e.stdout.contains("capsule 1  thawed"))
		#expect(e.stdout.hasSuffix("queue: 0\n"))
		e.stdout = ""
		#expect(e.run("status", "--json") == 0)
		let s = try CryoJSON.decoder().decode(Status.self, from: Data(e.stdout.utf8))
		#expect(s.capsules.count == 2)
		#expect(s.health?.leasesServed == 1)
		#expect(s.bay.alert == nil)
	}

	/// Taken subnets need a person: status says so, with the command.
	@Test func statusShowsTheBaysAlert() throws {
		let e = try Env()
		e.bay.alert = "capsule 0: vmnet subnet taken; run `sudo killall InternetSharing`"
		#expect(e.run("status") == 0)
		#expect(e.stdout.contains("doctor ok\nALERT: capsule 0: vmnet subnet taken; run `sudo killall InternetSharing`\n"))
	}

	/// Between restarts no bay answers; status reads the note the last one left.
	@Test func statusReadsTheRestartNoteWhenNoBayAnswers() throws {
		let e = try Env(startBay: false)
		let socket = e.path(".cryo/bay.sock")
		try makeDirs(e.path(".cryo"), mode: 0o700)
		#expect(e.runArgs(["status"], socket: socket) != 0)
		#expect(e.stderr.contains("no bay at"))
		#expect(!e.stdout.contains("ALERT"))

		let alert = "capsule 0, 1: vmnet subnet taken; run `sudo killall InternetSharing`"
		try writeAtomically(e.path(".cryo/" + RestartNote.fileName), RestartNote.text(alert: alert, now: Date().timeIntervalSince1970))
		e.stderr = ""
		#expect(e.runArgs(["status"], socket: socket) == 1)
		#expect(
			e.stdout == "bay: restarting every minute (no bay is up right now)\nALERT: capsule 0, 1: vmnet subnet taken; run `sudo killall InternetSharing`\n")

		// --json stays JSON.
		e.stdout = ""
		#expect(e.runArgs(["status", "--json"], socket: socket) == 1)
		let json = try CryoJSON.decoder().decode(JSONValue.self, from: Data(e.stdout.utf8))
		#expect(json == .object(["bay": .object(["state": .string("restarting"), "alert": .string(alert)])]))

		// A stale note (the bay stopped restarting) is ignored.
		let old = Date().timeIntervalSince1970 - RestartNote.maxAgeS - 10
		try writeAtomically(e.path(".cryo/" + RestartNote.fileName), RestartNote.text(alert: alert, now: old))
		e.stdout = ""
		#expect(e.runArgs(["status"], socket: socket) != 0)
		#expect(!e.stdout.contains("ALERT"))
	}
}

/// Backdates files a minute, past `forgetLeases`'s grace for just-saved leases.
func age(_ paths: String...) {
	let then = time(nil) - 60
	for p in paths {
		var tv = [timeval(tv_sec: then, tv_usec: 0), timeval(tv_sec: then, tv_usec: 0)]
		_ = utimes(p, &tv)
	}
}

@Suite struct SetupTests {
	let include = "Include ~/.cryo/ssh_config"

	@Test func answeringYesPrependsAtTop() throws {
		let e = try Env()
		try makeDirs(e.path(".ssh"), mode: 0o755)
		try writeAtomically(e.path(".ssh/config"), "Host x\n  User y\n", mode: 0o600)
		e.stdinIsTTY = true
		e.input = ["y"]
		#expect(e.run("setup") == 0)
		#expect(e.stdout.contains("Add it? [y/N]"))
		#expect(e.read(".ssh/config") == "\(include)\n\nHost x\n  User y\n")
		#expect(pathExists(e.path(".cryo/ssh_config")))
		// Idempotent.
		e.stdout = ""
		#expect(e.run("setup") == 0)
		#expect(e.read(".ssh/config") == "\(include)\n\nHost x\n  User y\n")
		#expect(e.stdout.contains("nothing to do"))
	}

	@Test func createsSSHDirAndConfig() throws {
		let e = try Env()
		#expect(e.run("setup", "--yes") == 0)
		#expect(fileMode(e.path(".ssh")) == 0o700)
		#expect(fileMode(e.path(".ssh/config")) == 0o600)
		#expect(e.read(".ssh/config") == "\(include)\n\n")
	}

	@Test func answeringNoChangesNothing() throws {
		let e = try Env()
		e.stdinIsTTY = true
		e.input = ["n"]
		#expect(e.run("setup") == 0)
		#expect(e.read(".ssh/config") == "")
		e.input = []
		#expect(e.run("setup") == 0)
		#expect(e.read(".ssh/config") == "")
	}

	@Test func nonTTYWithoutYesRefuses() throws {
		let e = try Env()
		#expect(e.run("setup") == 1)
		#expect(e.stderr.contains("--yes"))
		#expect(e.read(".ssh/config") == "")
	}

	@Test func alreadyPresentAnywhereIsLeftAlone() throws {
		let e = try Env()
		try makeDirs(e.path(".ssh"), mode: 0o700)
		let text = "Host a\n  User b\n\n  \(include)\n"
		try writeAtomically(e.path(".ssh/config"), text)
		#expect(e.run("setup", "--yes") == 0)
		#expect(e.read(".ssh/config") == text)
	}
}

@Suite struct SSHTests {
	@Test func ttyModeExecsSSHWithHostFromBlock() throws {
		let e = try Env()
		_ = e.run("lease")
		e.stdinIsTTY = true
		#expect(e.run("ssh", "L1") == 0)
		#expect(e.execs == [["ssh", "-F", e.path(".cryo/ssh_config"), "cryo-L1"]])
		_ = e.run("ssh", "L1", "ls", "-l")
		#expect(e.execs.last == ["ssh", "-F", e.path(".cryo/ssh_config"), "cryo-L1", "ls", "-l"])
	}

	/// Agents' shells have no terminal on stdin; a command still runs over ssh, never as ProxyCommand.
	@Test func commandRunsOverSSHWithoutATerminal() throws {
		let e = try Env()
		_ = e.run("lease")
		e.stdout = ""
		#expect(!e.stdinIsTTY)
		#expect(e.run("ssh", "L1", "uname", "-a") == 0)
		#expect(e.execs == [["ssh", "-F", e.path(".cryo/ssh_config"), "cryo-L1", "uname", "-a"]])
		#expect(e.stdout.isEmpty)
	}

	@Test func ttyModeFetchesLeaseWhenNoLocalBlock() throws {
		let e = try Env()
		_ = e.run("lease")
		LocalState(home: e.home).removeLease("L1")
		e.stdinIsTTY = true
		#expect(e.run("ssh", "L1") == 0)
		#expect(pathExists(e.path(".cryo/keys/L1")))
		#expect(e.execs.last == ["ssh", "-F", e.path(".cryo/ssh_config"), "cryo-L1"])
	}

	@Test func ttyModeUnknownLease() throws {
		let e = try Env()
		e.stdinIsTTY = true
		#expect(e.run("ssh", "L9") == 1)
		#expect(e.execs.isEmpty)
		#expect(e.stderr.contains("not_found"))
	}

	@Test func proxyModePipesThroughBayToEcho() throws {
		let e = try Env()
		let echo = EchoServer()
		try echo.start()
		defer { echo.stop() }
		e.bay.sshdPort = echo.port
		_ = e.run("lease")
		e.stdout = ""

		var inPipe: [Int32] = [0, 0]
		var outPipe: [Int32] = [0, 0]
		#expect(pipe(&inPipe) == 0)
		#expect(pipe(&outPipe) == 0)
		let payload = "SSH-2.0-test hello\r\n"
		_ = payload.withCString { write(inPipe[1], $0, payload.utf8.count) }
		close(inPipe[1])
		e.stdinFD = inPipe[0]
		e.stdoutFD = outPipe[1]
		#expect(e.run("ssh", "L1") == 0)
		close(outPipe[1])
		var got = [UInt8](repeating: 0, count: 256)
		let n = read(outPipe[0], &got, got.count)
		close(inPipe[0])
		close(outPipe[0])
		#expect(String(decoding: got[0..<max(n, 0)], as: UTF8.self) == payload)
		#expect(e.stdout.isEmpty)
		#expect(e.execs.isEmpty)
	}

	@Test func proxyModeErrorsGoToStderrOnly() throws {
		let e = try Env()
		#expect(e.run("ssh", "L9") == 1)
		#expect(e.stdout.isEmpty)
		#expect(e.stderr.contains("not_found"))
	}
}

@Suite struct LogsTests {
	private func withLog(_ text: String, _ body: (Int32, Int) throws -> Void) throws {
		var template = Array("/tmp/cryo-log-XXXXXX".utf8CString)
		let fd = mkstemp(&template)
		#expect(fd >= 0)
		let path = String(decoding: template.dropLast().map { UInt8(bitPattern: $0) }, as: UTF8.self)
		defer {
			close(fd)
			unlink(path)
		}
		try writeAll(fd, Array(text.utf8))
		try body(fd, text.utf8.count)
	}

	@Test func lastLinesTakesTheTail() throws {
		try withLog("a\nb\nc\n") { fd, size in
			#expect(String(decoding: lastLines(fd, size: size, count: 2), as: UTF8.self) == "b\nc\n")
			#expect(String(decoding: lastLines(fd, size: size, count: 3), as: UTF8.self) == "a\nb\nc\n")
			#expect(String(decoding: lastLines(fd, size: size, count: 9), as: UTF8.self) == "a\nb\nc\n")
			#expect(lastLines(fd, size: size, count: 0).isEmpty)
		}
		try withLog("a\nb\nno newline") { fd, size in
			#expect(String(decoding: lastLines(fd, size: size, count: 2), as: UTF8.self) == "b\nno newline")
		}
		// Across the 64 KB read chunks.
		let big = (0..<20_000).map { "line \($0)\n" }.joined()
		try withLog(big) { fd, size in
			let tail = String(decoding: lastLines(fd, size: size, count: 15_000), as: UTF8.self)
			#expect(tail.hasPrefix("line 5000\n") && tail.hasSuffix("line 19999\n"))
			#expect(tail.split(separator: "\n").count == 15_000)
		}
	}

	@Test func followPrintsWholeAppendedLinesAndStartsOverWhenTrimmed() throws {
		var template = Array("/tmp/cryo-log-XXXXXX".utf8CString)
		let w = mkstemp(&template)
		let path = String(decoding: template.dropLast().map { UInt8(bitPattern: $0) }, as: UTF8.self)
		defer {
			close(w)
			unlink(path)
		}
		try writeAll(w, Array("old\n".utf8))
		let r = open(path, O_RDONLY)
		defer { close(r) }
		var got = ""
		var step = 0
		followLog(
			path, fd: r, from: 4, out: { got += $0 }, interval: 1_000,
			keepGoing: {
				step += 1
				switch step {
				case 2: try? writeAll(w, Array("one\ntw".utf8))
				case 3: try? writeAll(w, Array("o\n".utf8))
				case 4:
					_ = ftruncate(w, 0)
					_ = lseek(w, 0, SEEK_SET)
				case 5: try? writeAll(w, Array("new\n".utf8))
				default: break
				}
				return step < 8
			})
		#expect(got == "one\ntwo\nnew\n")
	}

	@Test func argumentsAndMissingLog() throws {
		#expect(logsArguments(["-f", "-n", "5"]) == ["--follow", "--lines", "5"])
		#expect(logsArguments(["-n20"]) == ["--lines=20"])
		let e = try Env()
		#expect(e.run("logs", "-n", "x") == 2)
		#if os(macOS)
			e.stderr = ""
			#expect(e.run("logs") == 1)
			#expect(e.stderr.contains("cryo logs: no bay log at \(e.home)/.cryo/bay.log"))
			#expect(e.stderr.contains("subsystem == \"dev.rizwan.cryo.bay\""))
		#endif
	}

	#if os(macOS)
		@Test func printsTheTailOfTheBayLogUnderCryoHome() throws {
			let e = try Env()
			let root = e.path("bayroot")
			try makeDirs(root, mode: 0o700)
			try writeAtomically(root + "/bay.log", (1...80).map { "l\($0)\n" }.joined())
			let ctx = CLIContext(
				home: e.home, cwd: "/", environment: ["CRYO_HOME": root], target: CryoTarget(endpoint: .unix(path: e.bay.socketPath)),
				out: { e.stdout += $0 }, err: { e.stderr += $0 }, exec: { _ in 0 })
			#expect(CryoCLI.run(["logs", "-n", "3"], ctx) == 0)
			#expect(e.stdout == "l78\nl79\nl80\n")
			e.stdout = ""
			#expect(CryoCLI.run(["logs"], ctx) == 0)
			#expect(e.stdout.split(separator: "\n").count == defaultLogLines)
		}
	#endif
}

@Suite struct MiscTests {
	@Test func unknownCommandIsUsageError() throws {
		let e = try Env()
		#expect(e.run("frobnicate") == 2)
		#expect(e.stderr.contains("unknown command 'frobnicate'"))
		#expect(e.stderr.contains("usage: cryo"))
	}

	@Test func versionAndHelp() throws {
		let e = try Env()
		#expect(e.run("version") == 0)
		#expect(e.stdout == "cryo \(cryoVersion)\n")
		e.stdout = ""
		#expect(e.run("--help") == 0)
		#expect(e.stdout.contains("usage: cryo"))
		e.stdout = ""
		#expect(e.runArgs([]) == 0)
		#expect(e.stdout.contains("usage: cryo"))
	}

	#if !os(macOS)
		@Test func macOnlyCommandsOnLinux() throws {
			let e = try Env()
			for c in ["doctor", "bay"] {
				e.stderr = ""
				#expect(e.run(c) == 1)
				#expect(e.stderr == "cryo \(c): macOS bay only\n")
			}
			e.stderr = ""
			#expect(e.run("logs") == 1)
			#expect(e.stderr.hasPrefix("cryo logs: macOS bay only; on the bay's Mac its log is ~/.cryo/bay.log"))
		}
	#endif

	/// CI is a separate program (cryo-ci); `cryo ci …` hands the whole command line to it.
	@Test func ciRunsCryoCI() throws {
		let e = try Env()
		#expect(e.run("ci", "status", "--json") == 0)
		let argv = try #require(e.execs.last)
		#expect(argv.first == "cryo-ci" || argv.first?.hasSuffix("/cryo-ci") == true)
		#expect(Array(argv.dropFirst()) == ["status", "--json"])
	}

	@Test func bayHelpNamesRealCommands() throws {
		let e = try Env()
		#expect(e.run("help", "bay") == 0)
		#expect(!e.stdout.contains("stop|"))
		#expect(e.stdout.contains("launchctl bootout gui/$(id -u)/dev.rizwan.cryo.bay"))
		#expect(e.stdout.contains("launchctl kickstart -k gui/$(id -u)/dev.rizwan.cryo.bay"))
	}

	@Test func doctorCommandPrintsChecks() throws {
		let e = try Env()
		let ctx = CLIContext(
			home: e.home, cwd: "/", target: CryoTarget(endpoint: .unix(path: e.bay.socketPath)),
			out: { e.stdout += $0 }, err: { e.stderr += $0 }, exec: { _ in 0 })
		#expect(try doctorCommand(ctx, ParsedArgs()) == 0)
		#expect(e.stdout.contains("ok    host unlocked"))
	}

	@Test func argParser() throws {
		let spec = ArgSpec(values: ["a"], bools: ["b"])
		let p = try parseArgs(["x", "--a=1", "--b", "y", "--", "--z"], spec)
		#expect(p.values["a"] == "1")
		#expect(p.flag("b"))
		#expect(p.positionals == ["x", "y", "--z"])
		let q = try parseArgs(["--a", "2", "-h"], spec)
		#expect(q.values["a"] == "2" && q.help)
		let s = try parseArgs(["L1", "ls", "--b"], ArgSpec(stopAtPositional: true))
		#expect(s.positionals == ["L1", "ls", "--b"])
	}

	@Test func versionNoteOnlyForALocalBayThatDiffers() throws {
		let local = CryoTarget(endpoint: .unix(path: "/tmp/bay.sock"))
		let remote = CryoTarget(endpoint: .tcp(host: "10.0.0.5", port: 7477))
		#expect(
			bayVersionNote(target: local, bayVersion: "0.1.3", cliVersion: "0.2.0")
				== "note: the bay runs 0.1.3, this cryo is 0.2.0; restart it with `cryo bay restart`")
		#expect(bayVersionNote(target: local, bayVersion: "0.2.0", cliVersion: "0.2.0") == nil)
		#expect(bayVersionNote(target: remote, bayVersion: "0.1.3", cliVersion: "0.2.0") == nil)
	}
}

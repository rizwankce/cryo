import CryoAPI
import CryoClient
import CryoHTTP
import FakeBay
import Testing

@testable import CryoMCP

#if canImport(FoundationEssentials)
	import FoundationEssentials
#else
	import Foundation
#endif

/// Records argv instead of spawning ssh.
final class FakeRunner: CommandRunner, @unchecked Sendable {
	private let m = Monitor()
	private var _calls: [(argv: [String], timeout: Double)] = []
	private var _next = CommandResult(exitCode: 0)

	var calls: [(argv: [String], timeout: Double)] { m.withLock { _calls } }
	var next: CommandResult {
		get { m.withLock { _next } }
		set { m.withLock { _next = newValue } }
	}

	func run(argv: [String], timeout: Double) -> CommandResult {
		m.withLock {
			_calls.append((argv, timeout))
			return _next
		}
	}
}

/// A runner whose `run` blocks until `finish()` or `cancelRunning()`, like a long command.
final class BlockingRunner: CommandRunner, @unchecked Sendable {
	private let m = Monitor()
	private var _started = 0
	private var _cancelled = false
	private var _finished = false

	var started: Int { m.withLock { _started } }
	var cancelled: Bool { m.withLock { _cancelled } }

	func run(argv: [String], timeout: Double) -> CommandResult {
		m.withLock {
			_started += 1
			m.broadcast()
			while !_cancelled && !_finished { m.wait() }
			_finished = false
			return _cancelled ? CommandResult(exitCode: 137) : CommandResult(exitCode: 0, stdout: "done\n")
		}
	}

	func finish() {
		m.withLock {
			_finished = true
			m.broadcast()
		}
	}
	func cancelRunning() {
		m.withLock {
			_cancelled = true
			m.broadcast()
		}
	}
}

final class Lines: @unchecked Sendable {
	private let m = Monitor()
	private var items: [String] = []
	var all: [String] { m.withLock { items } }
	func add(_ s: String) { m.withLock { items.append(s) } }
}

/// A temp HOME, a FakeBay, a recording runner and a server wired to them.
final class Env: @unchecked Sendable {
	let home: String
	let bay = FakeBay()
	let runner = FakeRunner()
	let out = Lines()
	let client: CryoClient
	let server: MCPServer

	init(renewInterval: Double = 60, leaseWaitS: Int = MCPServer.defaultLeaseWaitS, inputFD: Int32 = 0, stopFD: Int32 = -1) throws {
		var template = Array("/tmp/cryo-mcp-XXXXXX".utf8CString)
		guard mkdtemp(&template) != nil else { throw FileError(description: "mkdtemp") }
		home = String(decoding: template.dropLast().map { UInt8(bitPattern: $0) }, as: UTF8.self)
		try bay.start()
		client = CryoClient(target: CryoTarget(endpoint: .unix(path: bay.socketPath)))
		let lines = out
		server = MCPServer(
			client: client, local: LocalState(home: home), runner: runner, renewInterval: renewInterval,
			leaseWaitS: leaseWaitS, inputFD: inputFD, stopFD: stopFD, executable: "/opt/cryo/bin/cryo", cwd: "/work/proj", version: "9.9.9",
			output: { lines.add($0) }, log: { _ in })
	}

	deinit {
		server.shutdown()
		bay.stop()
		try? FileManager.default.removeItem(atPath: home)
	}

	func path(_ rel: String) -> String { home + "/" + rel }

	/// Sends one request and returns the parsed response.
	func rpc(_ method: String, _ params: JSONValue? = nil, id: JSONValue = .number(1)) throws -> [String: JSONValue] {
		var req: [String: JSONValue] = ["jsonrpc": .string("2.0"), "id": id, "method": .string(method)]
		if let params { req["params"] = params }
		let reply = try #require(server.handle(line: JSONValue.object(req).line()))
		return try #require(try CryoJSON.decoder().decode(JSONValue.self, from: Data(reply.utf8)).objectValue)
	}

	func call(_ tool: String, _ args: [String: JSONValue] = [:]) throws -> Result {
		let r = try rpc("tools/call", .object(["name": .string(tool), "arguments": .object(args)]))
		let result = try #require(r["result"]?.objectValue)
		let text = result["content"].flatMap { v -> String? in
			if case .array(let a) = v { return a.first?.objectValue?["text"]?.stringValue }
			return nil
		}
		return Result(
			text: text ?? "", structured: result["structuredContent"]?.objectValue ?? [:],
			isError: result["isError"]?.boolValue ?? false)
	}

	struct Result {
		var text: String
		var structured: [String: JSONValue]
		var isError: Bool
	}

	func lease(_ args: [String: JSONValue] = [:]) throws -> String {
		let r = try call("lease_mac", args)
		#expect(!r.isError)
		return try #require(r.structured["lease"]?.stringValue)
	}
}

@Suite struct ProtocolTests {
	@Test func initializeEchoesKnownVersion() throws {
		let e = try Env()
		for v in ["2025-11-25", "2025-06-18", "2025-03-26"] {
			let r = try e.rpc("initialize", .object(["protocolVersion": .string(v), "capabilities": .object([:])]))
			let res = try #require(r["result"]?.objectValue)
			#expect(res["protocolVersion"]?.stringValue == v)
			#expect(res["capabilities"] == .object(["tools": .object([:])]))
			let info = try #require(res["serverInfo"]?.objectValue)
			#expect(info["name"]?.stringValue == "cryo")
			#expect(info["version"]?.stringValue == "9.9.9")
			#expect(res["instructions"]?.stringValue?.contains("/Volumes/My Shared Files") == true)
		}
	}

	@Test func initializeFallsBackForUnknownOrMissingVersion() throws {
		let e = try Env()
		// MCP: answer with the latest version the server supports.
		let a = try e.rpc("initialize", .object(["protocolVersion": .string("2099-01-01")]))
		#expect(a["result"]?.objectValue?["protocolVersion"]?.stringValue == "2025-11-25")
		let b = try e.rpc("initialize")
		#expect(b["result"]?.objectValue?["protocolVersion"]?.stringValue == "2025-11-25")
	}

	@Test func idsAreEchoedAsTheyCame() throws {
		let e = try Env()
		let reply = try #require(e.server.handle(line: #"{"jsonrpc":"2.0","id":7,"method":"ping"}"#))
		#expect(reply.contains(#""id":7"#) && !reply.contains("7.0"))
		let s = try e.rpc("ping", id: .string("abc"))
		#expect(s["id"]?.stringValue == "abc")
		#expect(s["result"] == .object([:]))
	}

	@Test func toolsListShape() throws {
		let e = try Env()
		let r = try e.rpc("tools/list")
		guard case .array(let tools) = try #require(r["result"]?.objectValue?["tools"]) else {
			Issue.record("tools is not an array")
			return
		}
		let names = tools.compactMap { $0.objectValue?["name"]?.stringValue }
		#expect(names == ["lease_mac", "run", "copy_in", "copy_out", "release_mac", "status"])
		let required: [String: [String]] = [
			"lease_mac": [], "run": ["lease", "command"], "copy_in": ["lease", "local", "remote"],
			"copy_out": ["lease", "remote", "local"], "release_mac": ["lease"], "status": [],
		]
		for t in tools {
			let o = try #require(t.objectValue)
			let name = try #require(o["name"]?.stringValue)
			#expect(o["description"]?.stringValue?.isEmpty == false)
			let schema = try #require(o["inputSchema"]?.objectValue)
			#expect(schema["type"]?.stringValue == "object")
			#expect(schema["properties"]?.objectValue != nil)
			guard case .array(let req) = try #require(schema["required"]) else { continue }
			#expect(req.compactMap(\.stringValue) == required[name])
		}
		#expect(e.bay.leases.isEmpty)  // listing needs no bay call
	}

	@Test func unknownMethodAndParseError() throws {
		let e = try Env()
		let r = try e.rpc("resources/list")
		#expect(r["error"]?.objectValue?["code"] == .number(-32601))
		let bad = try #require(e.server.handle(line: "{not json"))
		let parsed = try CryoJSON.decoder().decode(JSONValue.self, from: Data(bad.utf8))
		#expect(parsed.objectValue?["error"]?.objectValue?["code"] == .number(-32700))
		#expect(parsed.objectValue?["id"] == .null)
	}

	@Test func notificationsGetNoReply() throws {
		let e = try Env()
		#expect(e.server.handle(line: #"{"jsonrpc":"2.0","method":"notifications/initialized"}"#) == nil)
		#expect(e.server.handle(line: #"{"jsonrpc":"2.0","method":"no/such/thing"}"#) == nil)
		#expect(e.server.handle(line: "") == nil)
	}

	@Test func unknownToolIsAnRPCError() throws {
		let e = try Env()
		let r = try e.rpc("tools/call", .object(["name": .string("nope")]))
		#expect(r["error"]?.objectValue?["code"] == .number(-32602))
	}

	@Test func missingArgumentIsAToolError() throws {
		let e = try Env()
		let r = try e.call("run", ["lease": .string("L1")])
		#expect(r.isError)
		#expect(r.text.contains("command"))
	}
}

@Suite struct ToolTests {
	@Test func leaseMacWritesFilesAndSendsIdle() throws {
		let e = try Env()
		let r = try e.call("lease_mac", ["name": .string("job"), "cache": .string("app"), "folder": .string("repo")])
		#expect(!r.isError)
		#expect(r.text == "L1 ready. Run commands with run(lease: \"L1\", …). Work in /Volumes/My Shared Files.")
		#expect(r.structured["lease"]?.stringValue == "L1")
		#expect(r.structured["host"]?.stringValue == "cryo-L1")
		#expect(r.structured["ssh_config_path"]?.stringValue == e.path(".cryo/ssh_config"))
		let req = try #require(e.bay.lastLeaseRequest)
		#expect(req.idleS == 300)
		#expect(req.waitS == 30)
		#expect(req.name == "job" && req.cache == "app")
		#expect(req.folder == "/work/proj/repo")
		#expect(fileMode(e.path(".cryo/keys/L1")) == 0o600)
		#expect(blockIDs(readTextFile(e.path(".cryo/ssh_config")) ?? "") == ["L1"])
		#expect(e.server.trackedLeases == ["L1"])
	}

	@Test func leaseMacGivesUpOnAFullBayAndCanRetry() throws {
		let e = try Env(leaseWaitS: 1)
		let a = try e.lease()
		_ = try e.lease()
		let t0 = nowSeconds()
		let r = try e.call("lease_mac")
		#expect(nowSeconds() - t0 < 5)
		#expect(r.isError)
		#expect(r.text.contains("within 1 s") && r.text.contains("Call lease_mac again"))
		#expect(e.server.trackedLeases.count == 2)
		_ = try e.call("release_mac", ["lease": .string(a)])
		_ = try e.lease()
		#expect(e.server.trackedLeases.count == 2)
	}

	@Test func runBuildsSSHCommandAndMapsResult() throws {
		let e = try Env()
		let id = try e.lease()
		e.runner.next = CommandResult(exitCode: 3, stdout: "hello\n", stderr: "warn\n")
		let r = try e.call("run", ["lease": .string(id), "command": .string("echo hi; false"), "timeout": .number(42)])
		let call = try #require(e.runner.calls.last)
		#expect(call.timeout == 42)
		#expect(
			call.argv == [
				"ssh", "-F", e.path(".cryo/ssh_config"), "-o", "BatchMode=yes", "-o", "LogLevel=ERROR",
				"-o", "ProxyCommand=/opt/cryo/bin/cryo ssh L1", "cryo-L1", "--", "echo $$ >/tmp/cryo-mcp-run.pid; echo hi; false",
			])
		#expect(!r.isError)
		#expect(r.structured["exit_code"] == .number(3))
		#expect(r.structured["stdout"]?.stringValue == "hello\n")
		#expect(r.structured["stderr"]?.stringValue == "warn\n")
		#expect(r.structured["timed_out"] == .bool(false))
		#expect(r.text.contains("exit code 3") && r.text.contains("hello") && r.text.contains("warn"))
	}

	@Test func runDefaultsAndClampsTimeoutAndFlagsFailures() throws {
		let e = try Env()
		let id = try e.lease()
		_ = try e.call("run", ["lease": .string(id), "command": .string("x")])
		#expect(e.runner.calls.last?.timeout == 600)
		_ = try e.call("run", ["lease": .string(id), "command": .string("x"), "timeout": .number(99999)])
		#expect(e.runner.calls.last?.timeout == 3600)
		let bad = try e.call("run", ["lease": .string(id), "command": .string("x"), "timeout": .number(-1)])
		#expect(bad.isError)
		e.runner.next = CommandResult(exitCode: 137, timedOut: true)
		let before = e.runner.calls.count
		let t = try e.call("run", ["lease": .string(id), "command": .string("sleep 99")])
		#expect(t.isError)
		#expect(t.structured["timed_out"] == .bool(true))
		// Then a second ssh ends the command's process group in the VM.
		#expect(e.runner.calls.count == before + 2)
		#expect(e.runner.calls.last?.argv.last == "kill -KILL -- -$(cat /tmp/cryo-mcp-run.pid) 2>/dev/null; rm -f /tmp/cryo-mcp-run.pid")
		e.runner.next = CommandResult(exitCode: 255, stderr: "ssh: connect failed\n")
		#expect(try e.call("run", ["lease": .string(id), "command": .string("x")]).isError)
	}

	@Test func runNotesTruncation() throws {
		let e = try Env()
		let id = try e.lease()
		e.runner.next = CommandResult(exitCode: 0, stdout: "tail", stdoutTruncated: true)
		let r = try e.call("run", ["lease": .string(id), "command": .string("x")])
		#expect(r.structured["stdout_truncated"] == .bool(true))
		#expect(r.text.contains("truncated"))
	}

	@Test func proxyCommandQuotesUnusualPaths() throws {
		let e = try Env()
		let lines = e.out
		let s = MCPServer(
			client: e.client, local: LocalState(home: e.home), runner: e.runner, executable: "/Users/a b/it's%/cryo",
			output: { lines.add($0) }, log: { _ in })
		_ = try s.callForTest("lease_mac")
		_ = try s.callForTest("run", ["lease": .string("L1"), "command": .string("true")])
		let arg = try #require(e.runner.calls.last?.argv.first { $0.hasPrefix("ProxyCommand=") })
		#expect(arg == #"ProxyCommand='/Users/a b/it'\''s%%/cryo' ssh L1"#)
		s.shutdown()
	}

	@Test func copyInAndOut() throws {
		let e = try Env()
		let id = try e.lease()
		let opts = ["-F", e.path(".cryo/ssh_config"), "-o", "BatchMode=yes", "-o", "LogLevel=ERROR", "-o", "ProxyCommand=/opt/cryo/bin/cryo ssh L1", "-r"]
		let a = try e.call("copy_in", ["lease": .string(id), "local": .string("/tmp/src"), "remote": .string("/Volumes/My Shared Files/src")])
		#expect(!a.isError)
		#expect(e.runner.calls.last?.argv == ["scp"] + opts + ["/tmp/src", "cryo-L1:/Volumes/My Shared Files/src"])
		let b = try e.call("copy_out", ["lease": .string(id), "remote": .string("build.log"), "local": .string("/tmp/out")])
		#expect(!b.isError)
		#expect(e.runner.calls.last?.argv == ["scp"] + opts + ["cryo-L1:build.log", "/tmp/out"])
		e.runner.next = CommandResult(exitCode: 1, stderr: "scp: nope\n")
		let c = try e.call("copy_out", ["lease": .string(id), "remote": .string("x"), "local": .string("y")])
		#expect(c.isError && c.text.contains("scp: nope"))
	}

	@Test func releaseCleansUpAndRecordsSaveCache() throws {
		let e = try Env()
		let a = try e.lease()
		let b = try e.lease()
		let r = try e.call("release_mac", ["lease": .string(a), "save_cache": .bool(true)])
		#expect(!r.isError)
		#expect(e.bay.releases == [FakeBay.Release(id: a, saveCache: true)])
		#expect(!pathExists(e.path(".cryo/keys/\(a)")))
		#expect(blockIDs(readTextFile(e.path(".cryo/ssh_config")) ?? "") == [b])
		#expect(e.server.trackedLeases == [b])
		let again = try e.call("release_mac", ["lease": .string(a)])
		#expect(again.isError)
	}

	@Test func runOnUnknownLeaseIsAToolError() throws {
		let e = try Env()
		let r = try e.call("run", ["lease": .string("L9"), "command": .string("x")])
		#expect(r.isError && r.text.contains("L9"))
		#expect(e.runner.calls.isEmpty)
	}

	@Test func statusSummarisesTheBay() throws {
		let e = try Env()
		_ = try e.lease()
		let r = try e.call("status")
		#expect(!r.isError)
		#expect(r.text.contains("version fake") && r.text.contains("capsule 0: leased (L1)") && r.text.contains("queue: 0"))
		#expect(r.structured["queue"] == .number(0))
		#expect(r.structured["bay"]?.objectValue?["image"]?.stringValue == "fake-image")
	}

	@Test func bayDownIsAToolErrorNotAnRPCError() throws {
		let e = try Env()
		e.bay.stop()
		let r = try e.call("status")
		#expect(r.isError)
	}
}

extension MCPServer {
	/// A tools/call without the envelope.
	fileprivate func callForTest(_ tool: String, _ args: [String: JSONValue] = [:]) throws -> JSONValue {
		let req: JSONValue = .object([
			"jsonrpc": .string("2.0"), "id": .number(1), "method": .string("tools/call"),
			"params": .object(["name": .string(tool), "arguments": .object(args)]),
		])
		let reply = try #require(handle(line: req.line()))
		return try CryoJSON.decoder().decode(JSONValue.self, from: Data(reply.utf8))
	}
}

@Suite struct ReliabilityTests {
	private func openFDs() -> Int { listDir("/dev/fd").count }

	/// Three agents share one HOME and a two-capsule bay, so leases queue, and run 180 leases in a
	/// row: every one must succeed and leave no lease, key, ssh_config block or socket behind.
	@Test func manyLeasesFromAgentsSharingABay() throws {
		let e = try Env()
		let bay = e.bay
		let client = e.client
		let fdsBefore = openFDs()
		let agents = 3
		let rounds = 60
		let failures = Lines()
		let finished = Lines()
		for a in 0..<agents {
			let server = MCPServer(
				client: client, local: LocalState(home: e.home), runner: e.runner, leaseWaitS: 10,
				executable: "/opt/cryo/bin/cryo", output: { _ in }, log: { _ in })
			spawnThread {
				for i in 0..<rounds {
					do {
						let lease = try server.callForTest("lease_mac", ["name": .string("agent\(a)-\(i)")])
						let r = lease.objectValue?["result"]?.objectValue
						guard r?["isError"] != .bool(true), let id = r?["structuredContent"]?.objectValue?["lease"]?.stringValue else {
							failures.add("agent \(a) lease \(i): \(lease.line())")
							continue
						}
						// The lease's Host block must be there while it is held.
						if !blockIDs(readTextFile(LocalState(home: e.home).sshConfig) ?? "").contains(id) {
							failures.add("agent \(a): no ssh_config block for \(id)")
						}
						let run = try server.callForTest("run", ["lease": .string(id), "command": .string("true")])
						if run.objectValue?["result"]?.objectValue?["isError"] != .bool(false) { failures.add("run \(id): \(run.line())") }
						let rel = try server.callForTest("release_mac", ["lease": .string(id)])
						if rel.objectValue?["result"]?.objectValue?["isError"] != .bool(false) { failures.add("release \(id): \(rel.line())") }
					} catch { failures.add("agent \(a): \(error)") }
				}
				server.shutdown()
				finished.add("\(a)")
			}
		}
		let deadline = nowSeconds() + 60
		while finished.all.count < agents && nowSeconds() < deadline { usleep(20_000) }
		#expect(finished.all.count == agents)
		#expect(failures.all.isEmpty, "\(failures.all.prefix(5))")
		#expect(bay.releases.count == agents * rounds)
		#expect(bay.leases.isEmpty)
		let local = LocalState(home: e.home)
		#expect(blockIDs(readTextFile(local.sshConfig) ?? "x").isEmpty)
		#expect(listDir(local.keysDir).isEmpty)
		// The bay's connection threads close their ends just after replying.
		let fdDeadline = nowSeconds() + 2
		while openFDs() > fdsBefore + 4 && nowSeconds() < fdDeadline { usleep(20_000) }
		#expect(openFDs() <= fdsBefore + 4)
	}
}

@Suite struct KeepAliveTests {
	@Test func renewLoopRenewsTrackedLeases() throws {
		let e = try Env(renewInterval: 0.2)
		let id = try e.lease()
		let deadline = nowSeconds() + 5
		while e.bay.renews.count < 2 && nowSeconds() < deadline { usleep(50_000) }
		#expect(e.bay.renews.count >= 2)
		#expect(Set(e.bay.renews) == [id])
	}

	@Test func releasedLeasesAreNotRenewed() throws {
		let e = try Env(renewInterval: 0.2)
		let id = try e.lease()
		_ = try e.call("release_mac", ["lease": .string(id)])
		usleep(600_000)
		#expect(e.bay.renews.isEmpty)
	}

	@Test func lostLeaseIsReportedOnNextCall() throws {
		let e = try Env()
		let id = try e.lease()
		try e.client.release(id)  // behind the server's back
		let r = try e.call("run", ["lease": .string(id), "command": .string("true")])
		#expect(r.isError)
		#expect(r.text.contains("lease \(id) was lost"))
		#expect(r.text.contains("lease a new one"))
		#expect(e.runner.calls.isEmpty)
		#expect(e.server.trackedLeases.isEmpty)
		#expect(!pathExists(e.path(".cryo/keys/\(id)")))
		// Stays lost, for every tool.
		#expect(try e.call("copy_in", ["lease": .string(id), "local": .string("a"), "remote": .string("b")]).text.contains("was lost"))
		// release_mac on it just cleans up.
		#expect(try !e.call("release_mac", ["lease": .string(id)]).isError)
	}

	/// The bay ended the lease itself (idle timeout, restart): GET answers 410 lease_lost.
	@Test func leaseTheBayLostIsReportedBeforeRunning() throws {
		let e = try Env()
		let id = try e.lease()
		e.bay.loseLease(id)
		let r = try e.call("copy_out", ["lease": .string(id), "remote": .string("a"), "local": .string("b")])
		#expect(r.isError && r.text.contains("lease \(id) was lost"))
		#expect(e.runner.calls.isEmpty)
		#expect(e.server.trackedLeases.isEmpty)
		#expect(!pathExists(e.path(".cryo/keys/\(id)")))
	}

	@Test func renewLoopDropsLeasesTheBayLost() throws {
		let e = try Env(renewInterval: 0.2)
		let id = try e.lease()
		e.bay.loseLease(id)
		let deadline = nowSeconds() + 5
		while !e.server.trackedLeases.isEmpty && nowSeconds() < deadline { usleep(50_000) }
		#expect(e.server.trackedLeases.isEmpty)
		#expect(!pathExists(e.path(".cryo/keys/\(id)")))
		#expect(try e.call("run", ["lease": .string(id), "command": .string("true")]).text.contains("was lost"))
	}

	@Test func releasingALeaseTheBayLostJustCleansUp() throws {
		let e = try Env()
		let id = try e.lease()
		e.bay.loseLease(id)
		let r = try e.call("release_mac", ["lease": .string(id)])
		#expect(!r.isError)
		#expect(r.text == "\(id) released (the bay no longer had it)")
		#expect(e.server.trackedLeases.isEmpty)
		#expect(!pathExists(e.path(".cryo/keys/\(id)")))
	}

	@Test func renewLoopDropsLostLeases() throws {
		let e = try Env(renewInterval: 0.2)
		let id = try e.lease()
		try e.client.release(id)
		let deadline = nowSeconds() + 5
		while !e.server.trackedLeases.isEmpty && nowSeconds() < deadline { usleep(50_000) }
		#expect(e.server.trackedLeases.isEmpty)
		let r = try e.call("run", ["lease": .string(id), "command": .string("true")])
		#expect(r.isError && r.text.contains("was lost"))
	}
}

@Suite struct ShutdownTests {
	/// Close-on-exec, so a child another test spawns meanwhile can't hold the write end open
	/// (which kept EOF from arriving).
	private func pipePair() -> (Int32, Int32) {
		var fds: [Int32] = [-1, -1]
		#expect(pipe(&fds) == 0)
		for fd in fds { _ = fcntl(fd, F_SETFD, FD_CLOEXEC) }
		return (fds[0], fds[1])
	}

	private func send(_ fd: Int32, _ method: String, id: Int, _ params: String = "{}") {
		let msg = #"{"jsonrpc":"2.0","id":\#(id),"method":"\#(method)","params":\#(params)}"# + "\n"
		_ = msg.withCString { write(fd, $0, strlen($0)) }
	}

	private func blockingServer(_ e: Env, _ runner: BlockingRunner, inputFD: Int32, stopFD: Int32 = -1) throws -> (MCPServer, String) {
		let lines = e.out
		let s = MCPServer(
			client: e.client, local: LocalState(home: e.home), runner: runner, inputFD: inputFD, stopFD: stopFD,
			executable: "/opt/cryo/bin/cryo", output: { lines.add($0) }, log: { _ in })
		let reply = try s.callForTest("lease_mac")
		let id = try #require(reply.objectValue?["result"]?.objectValue?["structuredContent"]?.objectValue?["lease"]?.stringValue)
		return (s, id)
	}

	private func runParams(_ id: String) -> String {
		#"{"name":"run","arguments":{"lease":"\#(id)","command":"sleep 3600"}}"#
	}

	/// SIGTERM (the stop pipe) during a long run kills it, releases the lease and returns.
	@Test func stopInterruptsARunningToolCall() throws {
		let (r, w) = pipePair()
		let (sr, sw) = pipePair()
		let e = try Env()
		let runner = BlockingRunner()
		let (server, id) = try blockingServer(e, runner, inputFD: r, stopFD: sr)
		let served = Lines()
		spawnThread {
			server.serve()
			served.add("returned")
		}
		send(w, "tools/call", id: 1, runParams(id))
		#expect(waitUntil { runner.started == 1 })
		// ping is answered while the tool call runs; other requests wait for it.
		send(w, "tools/list", id: 2)
		send(w, "ping", id: 3)
		#expect(waitUntil { e.out.all.contains { $0.contains(#""id":3"#) } })
		#expect(!e.out.all.contains { $0.contains(#""id":2"#) })
		var b: UInt8 = 15
		_ = write(sw, &b, 1)
		#expect(waitUntil { served.all == ["returned"] })
		#expect(runner.cancelled)
		#expect(e.out.all.contains { $0.contains(#""id":1"#) && $0.contains("exit code 137") })
		#expect(e.bay.releases.map(\.id) == [id])
		#expect(e.bay.leases.isEmpty)
		#expect(!pathExists(e.path(".cryo/keys/\(id)")))
		for fd in [r, w, sr, sw] { close(fd) }
	}

	/// The client closing stdin during a long run does the same.
	@Test func eofInterruptsARunningToolCall() throws {
		let (r, w) = pipePair()
		let e = try Env()
		let runner = BlockingRunner()
		let (server, id) = try blockingServer(e, runner, inputFD: r)
		let served = Lines()
		spawnThread {
			server.serve()
			served.add("returned")
		}
		send(w, "tools/call", id: 1, runParams(id))
		#expect(waitUntil { runner.started == 1 })
		close(w)
		#expect(waitUntil { served.all == ["returned"] })
		#expect(runner.cancelled)
		#expect(e.bay.leases.isEmpty)
		close(r)
	}

	/// Requests sent during a tool call run after it, in order.
	@Test func requestsWaitForTheRunningToolCall() throws {
		let (r, w) = pipePair()
		let e = try Env()
		let runner = BlockingRunner()
		let (server, id) = try blockingServer(e, runner, inputFD: r)
		let served = Lines()
		spawnThread {
			server.serve()
			served.add("returned")
		}
		send(w, "tools/call", id: 1, runParams(id))
		#expect(waitUntil { runner.started == 1 })
		send(w, "tools/call", id: 2, runParams(id))
		send(w, "tools/list", id: 3)
		usleep(200_000)
		#expect(e.out.all.isEmpty)
		runner.finish()
		#expect(waitUntil { runner.started == 2 })
		#expect(e.out.all.count == 1 && e.out.all[0].contains(#""id":1"#))
		runner.finish()
		#expect(waitUntil { e.out.all.count == 3 })
		#expect(e.out.all.map { $0.contains(#""id":2"#) } == [false, true, false])
		#expect(e.out.all.last?.contains(#""id":3"#) == true)
		#expect(!runner.cancelled)
		close(w)
		#expect(waitUntil { served.all == ["returned"] })
		close(r)
	}

	private func waitUntil(_ cond: () -> Bool) -> Bool {
		let deadline = nowSeconds() + 5
		while !cond() && nowSeconds() < deadline { usleep(20_000) }
		return cond()
	}

	@Test func eofReleasesEveryTrackedLease() throws {
		let (r, w) = pipePair()
		let e = try Env(inputFD: r)
		let a = try e.lease()
		let b = try e.lease()
		let served = Lines()
		let lines = e.out
		spawnThread {
			e.server.serve()
			served.add("returned")
		}
		let msg = #"{"jsonrpc":"2.0","id":1,"method":"ping"}"# + "\n"
		_ = msg.withCString { write(w, $0, strlen($0)) }
		#expect(waitUntil { lines.all.count == 1 })
		#expect(lines.all.first?.contains(#""result":{}"#) == true)
		close(w)
		#expect(waitUntil { served.all == ["returned"] })
		#expect(Set(e.bay.releases.map(\.id)) == [a, b])
		#expect(e.bay.releases.allSatisfy { !$0.saveCache })
		#expect(e.bay.leases.isEmpty)
		#expect(listDir(e.path(".cryo/keys")).isEmpty)
		#expect(blockIDs(readTextFile(e.path(".cryo/ssh_config")) ?? "").isEmpty)
		close(r)
	}

	@Test func stopPipeReleasesToo() throws {
		let (r, w) = pipePair()  // stdin that never delivers
		let (sr, sw) = pipePair()
		let e = try Env(inputFD: r, stopFD: sr)
		_ = try e.lease()
		let served = Lines()
		spawnThread {
			e.server.serve()
			served.add("returned")
		}
		usleep(100_000)
		var b: UInt8 = 15
		_ = write(sw, &b, 1)
		#expect(waitUntil { served.all == ["returned"] })
		#expect(e.bay.leases.isEmpty)
		for fd in [r, w, sr, sw] { close(fd) }
	}

	@Test func requestWithoutTrailingNewlineIsHandledAtEOF() throws {
		let (r, w) = pipePair()
		let e = try Env(inputFD: r)
		let served = Lines()
		spawnThread {
			e.server.serve()
			served.add("returned")
		}
		let msg = #"{"jsonrpc":"2.0","id":1,"method":"ping"}"#
		_ = msg.withCString { write(w, $0, strlen($0)) }
		close(w)
		#expect(waitUntil { served.all == ["returned"] })
		#expect(e.out.all.count == 1)
		close(r)
	}
}

@Suite struct ProcessRunnerTests {
	let runner = ProcessRunner(outputCap: 1000)

	@Test func capturesOutputAndExitCode() {
		let r = runner.run(argv: ["/bin/sh", "-c", "echo out; echo err >&2; exit 7"], timeout: 10)
		#expect(r.exitCode == 7)
		#expect(r.stdout == "out\n")
		#expect(r.stderr == "err\n")
		#expect(!r.timedOut && !r.stdoutTruncated)
	}

	@Test func stdinIsEmpty() {
		let r = runner.run(argv: ["/bin/sh", "-c", "cat; echo done"], timeout: 10)
		#expect(r.stdout == "done\n")
	}

	@Test func timeoutKillsTheWholeProcessGroup() {
		let marker = "/tmp/cryo-mcp-grandchild-\(getpid())"
		unlink(marker)
		let start = nowSeconds()
		let r = runner.run(argv: ["/bin/sh", "-c", "(sleep 2; echo alive > \(marker)) & echo started; sleep 30"], timeout: 0.5)
		#expect(r.timedOut)
		#expect(r.exitCode == 137)
		#expect(r.stdout == "started\n")
		#expect(nowSeconds() - start < 5)
		usleep(2_500_000)
		#expect(!pathExists(marker), "the grandchild survived the kill")
		unlink(marker)
	}

	@Test func keepsTheTailOfLargeOutput() {
		let r = runner.run(argv: ["/bin/sh", "-c", "i=0; while [ $i -lt 3000 ]; do echo line$i; i=$((i+1)); done"], timeout: 20)
		#expect(r.exitCode == 0)
		#expect(r.stdoutTruncated && !r.stderrTruncated)
		#expect(r.stdout.utf8.count == 1000)
		#expect(r.stdout.hasSuffix("line2999\n"))
	}

	@Test func stopsWhenTheChildExitsEvenIfAGrandchildHoldsThePipe() {
		let start = nowSeconds()
		let r = runner.run(argv: ["/bin/sh", "-c", "sleep 5 & echo bye"], timeout: 20)
		#expect(r.stdout == "bye\n")
		#expect(nowSeconds() - start < 3)
	}

	@Test func missingProgramReports127() {
		let r = runner.run(argv: ["/nonexistent/prog"], timeout: 5)
		#expect(r.exitCode == 127)
		#expect(r.stderr.contains("/nonexistent/prog"))
	}

	@Test func cancelRunningKillsTheRunningChild() {
		let box = Lines()
		let runner = self.runner
		let start = nowSeconds()
		spawnThread {
			let r = runner.run(argv: ["/bin/sh", "-c", "echo started; sleep 30"], timeout: 60)
			box.add("\(r.exitCode) \(r.timedOut) \(r.stdout)")
		}
		usleep(300_000)
		runner.cancelRunning()
		let deadline = nowSeconds() + 5
		while box.all.isEmpty && nowSeconds() < deadline { usleep(20_000) }
		#expect(box.all == ["137 false started\n"])
		#expect(nowSeconds() - start < 3)
		// Later runs are not affected.
		#expect(runner.run(argv: ["/bin/sh", "-c", "exit 4"], timeout: 5).exitCode == 4)
	}

	@Test func signalDeathMapsTo128PlusSignal() {
		let r = runner.run(argv: ["/bin/sh", "-c", "kill -TERM $$"], timeout: 5)
		#expect(r.exitCode == 143)
	}
}

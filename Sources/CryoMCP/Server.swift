import CryoAPI
import CryoClient
import CryoHTTP

#if canImport(FoundationEssentials)
	import FoundationEssentials
#else
	import Foundation
#endif

/// MCP server over newline-delimited JSON-RPC 2.0 (stdio). Requests are handled one at a time, but
/// a tool call runs on its own thread so `ping` is answered meanwhile and a stop signal or EOF can
/// kill it; a background thread renews the leases this server created.
public final class MCPServer: @unchecked Sendable {
	/// Newest first. A client asking for another version (or none) gets the newest, as MCP says.
	public static let supportedProtocols = ["2025-11-25", "2025-06-18", "2025-03-26"]
	public static let fallbackProtocol = supportedProtocols[0]
	/// MCP leases idle out after 5 minutes (cli.md).
	public static let idleSeconds = 300
	/// lease_mac waits at most this long for a capsule. Requests are handled one at a time and MCP
	/// clients give up on a tool call after about a minute; a longer wait would block the server and
	/// hand it a lease after the agent stopped waiting, which it would then renew until it exits.
	public static let defaultLeaseWaitS = 30
	public static let defaultRunTimeout = 600.0
	public static let maxRunTimeout = 3600.0
	static let copyTimeout = 1800.0
	/// Where `run` leaves the pid of the VM shell running the command (one command at a time per lease).
	static let runPIDFile = "/tmp/cryo-mcp-run.pid"

	private struct Tracked {
		var host: String
	}

	private let client: CryoClient
	private let local: LocalState
	private let runner: CommandRunner
	private let renewInterval: Double
	private let leaseWaitS: Int
	private let inputFD: Int32
	private let stopFD: Int32
	private let output: @Sendable (String) -> Void
	private let log: @Sendable (String) -> Void
	private let executable: String
	private let cwd: String
	private let version: String

	private let m = Monitor()
	// Guarded by `m`.
	private var tracked: [String: Tracked] = [:]
	private var lost: Set<String> = []
	private var renewerStarted = false
	private var renewerRunning = false
	private var stopping = false
	private var finished = false
	/// A tool call is running on its worker thread.
	private var busy = false
	/// Keeps lines from the worker and the reading thread whole.
	private let outputLock = Monitor()

	/// - Parameters:
	///   - inputFD: where requests are read from (stdin).
	///   - stopFD: read end of a self-pipe that signal handlers write to; -1 for none.
	///   - output: called with one JSON line (no newline) per response, on the serving thread.
	public init(
		client: CryoClient, local: LocalState, runner: CommandRunner = ProcessRunner(),
		renewInterval: Double = 60, leaseWaitS: Int = MCPServer.defaultLeaseWaitS, inputFD: Int32 = 0, stopFD: Int32 = -1,
		executable: String? = nil, cwd: String? = nil, version: String = cryoVersion,
		output: @escaping @Sendable (String) -> Void,
		log: @escaping @Sendable (String) -> Void = { writeAll(2, "cryo mcp: " + $0 + "\n") }
	) {
		self.client = client
		self.local = local
		self.runner = runner
		self.renewInterval = renewInterval
		self.leaseWaitS = leaseWaitS
		self.inputFD = inputFD
		self.stopFD = stopFD
		self.output = output
		self.log = log
		self.executable = executable ?? currentExecutablePath()
		self.cwd = cwd ?? currentDirectory()
		self.version = version
	}

	// MARK: serving

	/// Reads requests until EOF or a stop signal, then releases every lease and returns. A tool call
	/// still running then is killed first: the client is gone or wants us gone, and may SIGKILL us
	/// next, which would leave the leases held until they idle out.
	public func serve() {
		var pending: [UInt8] = []
		// Requests that came while a tool call ran (other than ping), in order.
		var waiting: [String] = []
		var buf = [UInt8](repeating: 0, count: 64 * 1024)
		loop: while true {
			while !waiting.isEmpty && !isBusy { dispatch(waiting.removeFirst()) }
			var fds = [pollfd(fd: inputFD, events: Int16(POLLIN), revents: 0)]
			if stopFD >= 0 { fds.append(pollfd(fd: stopFD, events: Int16(POLLIN), revents: 0)) }
			// While a tool call runs, wake now and then to start what waits once it is done.
			let rc = poll(&fds, nfds_t(fds.count), waiting.isEmpty ? -1 : 50)
			if rc < 0 {
				if errno == EINTR { continue }
				break
			}
			if fds.count > 1 && fds[1].revents != 0 {
				log("signal received, shutting down")
				break
			}
			if fds[0].revents == 0 { continue }
			let n = read(inputFD, &buf, buf.count)
			if n < 0 && (errno == EINTR || errno == EAGAIN) { continue }
			if n <= 0 { break }
			pending.append(contentsOf: buf[0..<n])
			while let nl = pending.firstIndex(of: 10) {
				let line = String(decoding: pending[0..<nl], as: UTF8.self)
				pending.removeSubrange(0...nl)
				if !isBusy && waiting.isEmpty {
					dispatch(line)
				} else if isBusy && method(of: line) == "ping" {
					process(line)
				} else {
					waiting.append(line)
				}
			}
		}
		if isBusy {
			log("stopping the running tool call")
			interruptToolCall()
			if !waiting.isEmpty { log("dropping \(waiting.count) request(s) not started") }
		} else {
			// EOF after the last request: finish what was sent, as before.
			for line in waiting { process(line) }
			if !pending.isEmpty { process(String(decoding: pending, as: UTF8.self)) }
		}
		shutdown()
	}

	private var isBusy: Bool { m.withLock { busy } }

	/// Runs a tool call on a worker thread; anything else here and now.
	private func dispatch(_ line: String) {
		guard method(of: line) == "tools/call" else {
			process(line)
			return
		}
		m.withLock { busy = true }
		spawnThread { [self] in
			process(line)
			m.withLock {
				busy = false
				m.broadcast()
			}
		}
	}

	/// Kills the running tool call's process until its worker is done. Repeated, since the worker
	/// may start ssh just after a kill; a lease_mac waiting for a capsule ends on its own (`leaseWaitS`).
	private func interruptToolCall() {
		while true {
			runner.cancelRunning()
			let done: Bool = m.withLock {
				if busy { m.wait(until: nowSeconds() + 0.1) }
				return !busy
			}
			if done { return }
		}
	}

	private func method(of line: String) -> String? {
		guard let msg = try? CryoJSON.decoder().decode(JSONValue.self, from: Data(line.trimmingSpaces().utf8)) else { return nil }
		return msg.objectValue?["method"]?.stringValue
	}

	private func process(_ line: String) {
		if let reply = handle(line: line) { outputLock.withLock { output(reply) } }
	}

	/// Handles one JSON-RPC message; returns the response line, or nil for notifications.
	public func handle(line: String) -> String? {
		let trimmed = line.trimmingSpaces()
		if trimmed.isEmpty { return nil }
		guard let msg = try? CryoJSON.decoder().decode(JSONValue.self, from: Data(trimmed.utf8)) else {
			return rpcError(id: .null, code: RPCCode.parseError, "parse error").line()
		}
		guard case .object(let obj) = msg else {
			return rpcError(id: .null, code: RPCCode.invalidRequest, "expected a JSON-RPC request object").line()
		}
		guard let method = obj["method"]?.stringValue else {
			// A response to something we never sent, or garbage: nothing to answer.
			if obj["result"] != nil || obj["error"] != nil { return nil }
			return rpcError(id: obj["id"] ?? .null, code: RPCCode.invalidRequest, "missing method").line()
		}
		// No id: a notification, never answered.
		guard let id = obj["id"] else { return nil }
		let params = obj["params"]?.objectValue ?? [:]

		switch method {
		case "initialize":
			return rpcResult(id: id, initializeResult(params)).line()
		case "ping":
			return rpcResult(id: id, .object([:])).line()
		case "tools/list":
			return rpcResult(id: id, .object(["tools": .array(toolDefinitions)])).line()
		case "tools/call":
			guard let name = params["name"]?.stringValue else {
				return rpcError(id: id, code: RPCCode.invalidParams, "tools/call needs a tool name").line()
			}
			guard toolDefinitions.contains(where: { $0.objectValue?["name"]?.stringValue == name }) else {
				return rpcError(id: id, code: RPCCode.invalidParams, "unknown tool \(name)").line()
			}
			let args = params["arguments"]?.objectValue ?? [:]
			return rpcResult(id: id, callTool(name, args).json).line()
		default:
			return rpcError(id: id, code: RPCCode.methodNotFound, "method not found: \(method)").line()
		}
	}

	private func initializeResult(_ params: [String: JSONValue]) -> JSONValue {
		let asked = params["protocolVersion"]?.stringValue
		let chosen = asked.flatMap { MCPServer.supportedProtocols.contains($0) ? $0 : nil } ?? MCPServer.fallbackProtocol
		return .object([
			"protocolVersion": .string(chosen),
			"capabilities": .object(["tools": .object([:])]),
			"serverInfo": .object(["name": .string("cryo"), "version": .string(version)]),
			"instructions": .string(serverInstructions),
		])
	}

	// MARK: tools

	private struct ArgError: Error { let message: String }

	private func str(_ a: [String: JSONValue], _ key: String, required: Bool = false) throws -> String? {
		guard let v = a[key], v != .null else {
			if required { throw ArgError(message: "missing argument '\(key)'") }
			return nil
		}
		guard let s = v.stringValue else { throw ArgError(message: "argument '\(key)' must be a string") }
		if required && s.isEmpty { throw ArgError(message: "argument '\(key)' must not be empty") }
		return s
	}

	private func callTool(_ name: String, _ a: [String: JSONValue]) -> ToolOutput {
		do {
			switch name {
			case "lease_mac": return try leaseMac(a)
			case "run": return try runTool(a)
			case "copy_in":
				let id = try str(a, "lease", required: true)!
				return try copy(id, local: try str(a, "local", required: true)!, remote: try str(a, "remote", required: true)!, toRemote: true)
			case "copy_out":
				let id = try str(a, "lease", required: true)!
				return try copy(id, local: try str(a, "local", required: true)!, remote: try str(a, "remote", required: true)!, toRemote: false)
			case "release_mac": return try releaseMac(a)
			case "status": return try statusTool()
			default: return .failure("unknown tool \(name)")
			}
		} catch let e as ArgError {
			return .failure("\(name): \(e.message)")
		} catch {
			return .failure("\(name): \(describeError(error))")
		}
	}

	private func describeError(_ error: Error) -> String {
		if let e = error as? CryoClientError { return e.description }
		return "\(error)"
	}

	private func leaseMac(_ a: [String: JSONValue]) throws -> ToolOutput {
		let folder = try str(a, "folder").map { absolutePath($0, cwd: cwd) }
		let req = LeaseRequest(folder: folder, cache: try str(a, "cache"), waitS: leaseWaitS, name: try str(a, "name"), idleS: MCPServer.idleSeconds)
		let lease: Lease
		do {
			lease = try client.createLease(req)
		} catch CryoClientError.api(let e, _) where e.code == APIError.noCapacity {
			return .failure(
				"lease_mac: no capsule became free within \(leaseWaitS) s (\(e.message)); other leases hold them. Call lease_mac again to keep waiting, or status to see the bay"
			)
		}
		do {
			try local.saveLease(lease, bay: client.target)
		} catch {
			try? client.release(lease.id)
			throw error
		}
		track(lease)
		let text = "\(lease.id) ready. Run commands with run(lease: \"\(lease.id)\", …). Work in \(leaseFolderPath)."
		return ToolOutput(
			text: text,
			structured: [
				"lease": .string(lease.id), "host": .string(lease.ssh.host),
				"ssh_config_path": .string(local.sshConfig),
			])
	}

	/// The tracked host for `id`, after checking with the bay that the lease still exists.
	private func liveHost(_ id: String) throws -> String {
		let state: (Tracked?, Bool) = m.withLock { (tracked[id], lost.contains(id)) }
		if state.1 { throw lostError(id) }
		guard let t = state.0 else {
			throw ArgError(message: "unknown lease \(id): it was already released or never leased here; call lease_mac for a new one")
		}
		do {
			_ = try client.lease(id)
		} catch CryoClientError.api(let e, _) where e.code == APIError.notFound || e.code == APIError.leaseLost {
			markLost(id)
			throw lostError(id)
		} catch {
			// The bay is unreachable right now; let the command try and report its own failure.
		}
		return t.host
	}

	private func lostError(_ id: String) -> ArgError {
		ArgError(message: "lease \(id) was lost (bay restarted or it expired); lease a new one with lease_mac")
	}

	private func sshOptions(_ id: String) -> [String] {
		["-F", local.sshConfig, "-o", "BatchMode=yes", "-o", "LogLevel=ERROR", "-o", "ProxyCommand=\(proxyCommand(id))"]
	}

	/// `<self> ssh <id>`, quoted for the shell ssh runs it in.
	private func proxyCommand(_ id: String) -> String { sshProxyCommand(executable: executable, leaseID: id) }

	private func runTool(_ a: [String: JSONValue]) throws -> ToolOutput {
		let id = try str(a, "lease", required: true)!
		let command = try str(a, "command", required: true)!
		var timeout = MCPServer.defaultRunTimeout
		if let t = a["timeout"], t != .null {
			guard let n = t.numberValue, n > 0 else { throw ArgError(message: "argument 'timeout' must be a positive number of seconds") }
			timeout = min(n, MCPServer.maxRunTimeout)
		}
		let host = try liveHost(id)
		// The VM's shell notes its pid, which is also the process group sshd gave the session, so a
		// timeout can end the command there too: killing the local ssh doesn't stop it in the VM.
		let argv = ["ssh"] + sshOptions(id) + [host, "--", "echo $$ >\(MCPServer.runPIDFile); " + command]
		let r = runner.run(argv: argv, timeout: timeout)
		var stopNote = ""
		if r.timedOut {
			let kill = "kill -KILL -- -$(cat \(MCPServer.runPIDFile)) 2>/dev/null; rm -f \(MCPServer.runPIDFile)"
			let k = runner.run(argv: ["ssh"] + sshOptions(id) + [host, "--", kill], timeout: 30)
			if k.exitCode != 0 || k.timedOut { stopNote = " (could not stop it in the VM: it may still be running)" }
		}

		var structured: [String: JSONValue] = [
			"exit_code": .number(Double(r.exitCode)), "stdout": .string(r.stdout),
			"stderr": .string(r.stderr), "timed_out": .bool(r.timedOut),
		]
		if r.stdoutTruncated { structured["stdout_truncated"] = .bool(true) }
		if r.stderrTruncated { structured["stderr_truncated"] = .bool(true) }
		var text = r.timedOut ? "timed out after \(Int(timeout)) s and killed\(stopNote)\n" : "exit code \(r.exitCode)\n"
		if !r.stdout.isEmpty {
			text += "--- stdout\(r.stdoutTruncated ? " (truncated, last \(r.stdout.utf8.count) bytes)" : "") ---\n" + r.stdout
			if !r.stdout.hasSuffix("\n") { text += "\n" }
		}
		if !r.stderr.isEmpty {
			text += "--- stderr\(r.stderrTruncated ? " (truncated, last \(r.stderr.utf8.count) bytes)" : "") ---\n" + r.stderr
			if !r.stderr.hasSuffix("\n") { text += "\n" }
		}
		// 255 is ssh's own failure code (connection or ProxyCommand problems).
		let failed = r.timedOut || r.exitCode == 255
		return ToolOutput(text: text, structured: structured, isError: failed)
	}

	private func copy(_ id: String, local localPath: String, remote: String, toRemote: Bool) throws -> ToolOutput {
		let host = try liveHost(id)
		let target = "\(host):\(remote)"
		let argv = ["scp"] + sshOptions(id) + ["-r"] + (toRemote ? [localPath, target] : [target, localPath])
		let r = runner.run(argv: argv, timeout: MCPServer.copyTimeout)
		let ok = r.exitCode == 0 && !r.timedOut
		var text =
			ok
			? "copied \(toRemote ? "\(localPath) to \(remote)" : "\(remote) to \(localPath)")"
			: (r.timedOut ? "copy timed out and was killed" : "copy failed (exit code \(r.exitCode))")
		let detail = r.stderr.isEmpty ? r.stdout : r.stderr
		if !ok && !detail.isEmpty { text += "\n" + detail }
		return ToolOutput(
			text: text,
			structured: ["exit_code": .number(Double(r.exitCode)), "timed_out": .bool(r.timedOut)],
			isError: !ok)
	}

	private func releaseMac(_ a: [String: JSONValue]) throws -> ToolOutput {
		let id = try str(a, "lease", required: true)!
		let save = a["save_cache"]?.boolValue ?? false
		let wasTracked = m.withLock { tracked.removeValue(forKey: id) }
		let wasLost = m.withLock { lost.remove(id) != nil }
		if wasTracked == nil && !wasLost {
			throw ArgError(message: "unknown lease \(id): it was already released or never leased here")
		}
		var note = ""
		do {
			try client.release(id, saveCache: save)
		} catch CryoClientError.api(let e, _) where e.code == APIError.notFound || e.code == APIError.leaseLost {
			note = " (the bay no longer had it)"
		} catch {
			if let t = wasTracked { m.withLock { tracked[id] = t } }  // keep renewing; the caller may retry
			throw error
		}
		local.removeLease(id)
		return ToolOutput(text: "\(id) released\(note)", structured: ["lease": .string(id), "released": .bool(true)])
	}

	private func statusTool() throws -> ToolOutput {
		let s = try client.status()
		var text = "bay: version \(s.bay.version), image \(s.bay.image), doctor \(s.bay.doctorOK ? "ok" : "failing")\n"
		if let blocked = s.bay.blockedBy { text += "capsules frozen until these pass: \(blocked.joined(separator: "; "))\n" }
		for c in s.capsules { text += "capsule \(c.n): \(c.state)\(c.lease.map { " (\($0))" } ?? "")\n" }
		text += "queue: \(s.queue)"
		guard case .object(let o) = JSONValue.encoding(s) else { return ToolOutput(text: text) }
		return ToolOutput(text: text, structured: o)
	}

	// MARK: keep-alive

	private func track(_ lease: Lease) {
		let start: Bool = m.withLock {
			tracked[lease.id] = Tracked(host: lease.ssh.host)
			lost.remove(lease.id)
			if renewerStarted || stopping { return false }
			renewerStarted = true
			renewerRunning = true
			return true
		}
		if start { spawnThread { [self] in renewLoop() } }
	}

	private func markLost(_ id: String) {
		let was = m.withLock { () -> Bool in
			let had = tracked.removeValue(forKey: id) != nil
			if had { lost.insert(id) }
			return had
		}
		if was { local.removeLease(id) }
	}

	private func renewLoop() {
		while true {
			let ids: [String]? = m.withLock {
				let deadline = nowSeconds() + renewInterval
				while !stopping && nowSeconds() < deadline { m.wait(until: deadline) }
				return stopping ? nil : Array(tracked.keys)
			}
			guard let ids else { break }
			for id in ids {
				if m.withLock({ stopping }) { break }
				do {
					try client.renew(id)
				} catch CryoClientError.api(let e, _) where e.code == APIError.notFound || e.code == APIError.leaseLost {
					log("lease \(id) lost: \(e.message)")
					markLost(id)
				} catch {
					log("cannot renew \(id): \(describeError(error)) (will retry)")
				}
			}
		}
		m.withLock {
			renewerRunning = false
			m.broadcast()
		}
	}

	// MARK: shutdown

	/// Stops renewing, releases every tracked lease (best effort) and removes the local files.
	/// Safe to call more than once.
	public func shutdown() {
		let ids: [String] = m.withLock {
			if finished { return [] }
			finished = true
			stopping = true
			m.broadcast()
			while renewerRunning { m.wait(until: nowSeconds() + 0.05) }
			let ids = Array(tracked.keys)
			tracked.removeAll()
			return ids
		}
		var quick = client
		quick.timeout = 5
		for id in ids {
			do {
				try quick.release(id)
			} catch {
				log("cannot release \(id): \(describeError(error)) (it expires on its own)")
			}
			local.removeLease(id)
		}
	}

	/// Ids of the leases currently tracked (for tests).
	public var trackedLeases: [String] { m.withLock { tracked.keys.sorted() } }
}

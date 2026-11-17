import CryoAPI
import CryoClient
import CryoHTTP
import FakeBay
import Foundation
import Testing

@testable import CryoMCP

/// Records argv instead of spawning ssh.
final class RecordingRunner: CommandRunner, @unchecked Sendable {
	private let m = Monitor()
	private var _calls: [[String]] = []
	var calls: [[String]] { m.withLock { _calls } }

	func run(argv: [String], timeout: Double) -> CommandResult {
		m.withLock { _calls.append(argv) }
		return CommandResult(exitCode: 0, stdout: "ok\n")
	}
}

final class MCPLines: @unchecked Sendable {
	private let m = Monitor()
	private var items: [String] = []
	func add(_ s: String) { m.withLock { items.append(s) } }
}

/// `cryo mcp` pointed at a deck.
final class MCPRun: @unchecked Sendable {
	let home: String
	let runner = RecordingRunner()
	let server: MCPServer

	init(client: CryoClient, renewInterval: Double = 60) throws {
		home = try makeTempDir()
		let lines = MCPLines()
		server = MCPServer(
			client: client, local: LocalState(home: home), runner: runner, renewInterval: renewInterval,
			inputFD: 0, stopFD: -1, executable: "/opt/cryo/bin/cryo", cwd: "/work/proj", version: "9.9.9",
			output: { lines.add($0) }, log: { _ in })
	}

	deinit {
		server.shutdown()
		try? FileManager.default.removeItem(atPath: home)
	}

	func path(_ rel: String) -> String { home + "/" + rel }

	struct Reply: Sendable {
		var text: String
		var structured: [String: JSONValue]
		var isError: Bool
	}

	func call(_ tool: String, _ args: [String: JSONValue] = [:]) -> Reply? {
		let req: JSONValue = .object([
			"jsonrpc": .string("2.0"), "id": .number(1), "method": .string("tools/call"),
			"params": .object(["name": .string(tool), "arguments": .object(args)]),
		])
		guard
			let reply = server.handle(line: req.line()),
			let obj = try? CryoJSON.decoder().decode(JSONValue.self, from: Data(reply.utf8)).objectValue,
			let result = obj["result"]?.objectValue
		else { return nil }
		var text = ""
		if case .array(let a)? = result["content"] { text = a.first?.objectValue?["text"]?.stringValue ?? "" }
		return Reply(
			text: text, structured: result["structuredContent"]?.objectValue ?? [:], isError: result["isError"]?.boolValue ?? false)
	}
}

@Suite(.serialized) struct MCPCompatTests {
	@Test func leaseMacReturnsTheDeckLease() async throws {
		try await withDeck { fx, _ in
			let mcp = try MCPRun(client: fx.client())
			let r = try #require(try await blocking { mcp.call("lease_mac", ["name": .string("job"), "cache": .string("app")]) })
			#expect(!r.isError)
			#expect(r.structured["lease"]?.stringValue == "D1")
			#expect(r.structured["host"]?.stringValue == "cryo-D1")
			#expect(r.text.contains("D1 ready"))
			#expect(fileMode(mcp.path(".cryo/keys/D1")) == 0o600)
			#expect(blockIDs(readTextFile(mcp.path(".cryo/ssh_config")) ?? "") == ["D1"])
			#expect(mcp.server.trackedLeases == ["D1"])
			// The idle timeout and name reach the bay; the deck tells the bay not to queue.
			let sent = try #require(fx.bays[0].lastLeaseRequest)
			#expect(sent.idleS == 300 && sent.name == "job" && sent.cache == "app" && sent.waitS == 0)
		}
	}

	@Test func runUsesTheDeckHostAndProxyCommand() async throws {
		try await withDeck { fx, _ in
			let mcp = try MCPRun(client: fx.client())
			let lease = try #require(try await blocking { mcp.call("lease_mac") }?.structured["lease"]?.stringValue)
			let r = try #require(try await blocking { mcp.call("run", ["lease": .string(lease), "command": .string("uname")]) })
			#expect(!r.isError)
			let argv = try #require(mcp.runner.calls.last)
			#expect(argv.contains("cryo-D1"))
			#expect(argv.contains("ProxyCommand=/opt/cryo/bin/cryo ssh D1"))
		}
	}

	@Test func releaseMacReleasesOnTheOwningBay() async throws {
		try await withDeck { fx, _ in
			let mcp = try MCPRun(client: fx.client())
			let a = try #require(try await blocking { mcp.call("lease_mac") }?.structured["lease"]?.stringValue)
			let b = try #require(try await blocking { mcp.call("lease_mac") }?.structured["lease"]?.stringValue)
			#expect([a, b] == ["D1", "D2"])
			let r = try #require(
				try await blocking { mcp.call("release_mac", ["lease": .string(b), "save_cache": .bool(true)]) })
			#expect(!r.isError)
			#expect(fx.bays[1].releases == [FakeBay.Release(id: "L1", saveCache: true)])
			#expect(fx.bays[0].releases.isEmpty)
			#expect(!pathExists(mcp.path(".cryo/keys/D2")))
			#expect(mcp.server.trackedLeases == ["D1"])
			#expect(blockIDs(readTextFile(mcp.path(".cryo/ssh_config")) ?? "") == ["D1"])
			let again = try #require(try await blocking { mcp.call("release_mac", ["lease": .string(b)]) })
			#expect(again.isError)
		}
	}

	@Test func statusToolSeesTheMergedPool() async throws {
		try await withDeck { fx, _ in
			let mcp = try MCPRun(client: fx.client())
			_ = try await blocking { mcp.call("lease_mac") }
			let r = try #require(try await blocking { mcp.call("status") })
			#expect(!r.isError)
			#expect(r.text.contains("capsule 0: leased (D1)"))
			#expect(r.text.contains("queue: 0"))
			#expect(r.structured["queue"] == .number(0))
		}
	}

	@Test func theRenewLoopRenewsTheDeckLeaseOnItsBay() async throws {
		try await withDeck { fx, _ in
			let mcp = try MCPRun(client: fx.client(), renewInterval: 0.2)
			_ = try await blocking { mcp.call("lease_mac") }
			#expect(await waitUntil { fx.bays[0].renews.count >= 2 })
			#expect(Set(fx.bays[0].renews) == ["L1"])
		}
	}

	@Test func releasingAnUnknownDeckLeaseIsAToolError() async throws {
		try await withDeck(bays: 1, capacity: 1) { fx, _ in
			let mcp = try MCPRun(client: fx.client())
			_ = try await blocking { mcp.call("lease_mac") }
			let r = try #require(try await blocking { mcp.call("release_mac", ["lease": .string("D9")]) })
			#expect(r.isError)
			#expect(fx.bays[0].leases.count == 1)
		}
	}
}

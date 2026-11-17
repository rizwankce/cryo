import CryoAPI
import CryoClient
import CryoHTTP
import FakeBay
import Foundation
import Testing

@testable import CryoCLI

/// The CLI is pointed at a deck (CRYO_URL + CRYO_TOKEN, or the deck's socket) and should not
/// notice it is not a bay.
final class CLIRun: @unchecked Sendable {
	let home: String
	let target: CryoTarget
	private let m = Monitor()
	private var _out = ""
	private var _err = ""

	init(target: CryoTarget) throws {
		home = try makeTempDir()
		self.target = target
	}

	deinit { try? FileManager.default.removeItem(atPath: home) }

	var out: String { m.withLock { _out } }
	var err: String { m.withLock { _err } }

	func run(_ args: [String]) -> Int32 {
		let ctx = CLIContext(
			home: home, cwd: "/work/proj", target: target,
			out: { [self] s in m.withLock { _out += s } }, err: { [self] s in m.withLock { _err += s } },
			readLine: { nil }, stdinIsTTY: false, exec: { _ in 0 })
		return CryoCLI.run(args, ctx)
	}

	func clear() {
		m.withLock {
			_out = ""
			_err = ""
		}
	}

	func path(_ rel: String) -> String { home + "/" + rel }
	func read(_ rel: String) -> String? { readTextFile(path(rel)) }
}

extension DeckFixture {
	/// A CLI context for the deck over TCP with its token, or over its socket.
	func cli(viaSocket: Bool = false) throws -> CLIRun {
		let target =
			viaSocket
			? CryoTarget(endpoint: .unix(path: socketPath))
			: CryoTarget(endpoint: .tcp(host: "127.0.0.1", port: port), token: deckToken)
		return try CLIRun(target: target)
	}
}

@Suite(.serialized) struct CLICompatTests {
	@Test func leaseWritesTheKeyAndTheConfigForTheDeckID() async throws {
		try await withDeck { fx, _ in
			let cli = try fx.cli()
			let got1 = try await blocking { cli.run(["lease"]) }
			#expect(got1 == 0)
			#expect(cli.out == "D1 ready: ssh cryo-D1\n")
			#expect(fileMode(cli.path(".cryo/keys/D1")) == 0o600)
			#expect(cli.read(".cryo/keys/D1")?.contains("fake-key-L1") == true)
			let cfg = try #require(cli.read(".cryo/ssh_config"))
			#expect(cfg.hasPrefix("# cryo lease D1\nHost cryo-D1\n"))
			#expect(cfg.contains("ProxyCommand cryo ssh D1\n"))
			#expect(cfg.contains("UserKnownHostsFile ~/.cryo/known_hosts/D1\n"))
			#expect(cfg.hasSuffix("# end cryo lease D1\n"))
			#expect(!cfg.contains("L1"))
			#expect(cli.read(".cryo/known_hosts/D1") == "cryo-D1 ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIFakeHostKeyL1\n")
			#expect(blockIDs(cfg) == ["D1"])
		}
	}

	@Test func theSocketWorksLikeTheTCPPort() async throws {
		try await withDeck(bays: 1) { fx, _ in
			let cli = try fx.cli(viaSocket: true)
			let got2 = try await blocking { cli.run(["lease"]) }
			#expect(got2 == 0)
			#expect(cli.out == "D1 ready: ssh cryo-D1\n")
		}
	}

	@Test func twoLeasesLandOnTwoBays() async throws {
		try await withDeck { fx, _ in
			let cli = try fx.cli()
			let got3 = try await blocking { cli.run(["lease", "--name", "one"]) }
			#expect(got3 == 0)
			let got4 = try await blocking { cli.run(["lease", "--cache", "app"]) }
			#expect(got4 == 0)
			#expect(cli.out == "D1 ready: ssh cryo-D1\nD2 ready: ssh cryo-D2\n")
			#expect(fx.bays.map(\.leases.count) == [1, 1])
			#expect(fx.bays[0].lastLeaseRequest?.name == "one")
			#expect(fx.bays[1].lastLeaseRequest?.cache == "app")
			#expect(blockIDs(cli.read(".cryo/ssh_config") ?? "").sorted() == ["D1", "D2"])
		}
	}

	@Test func lsListsTheDecksLeases() async throws {
		try await withDeck { fx, _ in
			let cli = try fx.cli()
			let got5 = try await blocking { cli.run(["ls"]) }
			#expect(got5 == 0)
			#expect(cli.out == "no leases\n")
			cli.clear()
			_ = try await blocking { cli.run(["lease", "--name", "job"]) }
			_ = try await blocking { cli.run(["lease"]) }
			cli.clear()
			let got6 = try await blocking { cli.run(["ls"]) }
			#expect(got6 == 0)
			let rows = cli.out.split(separator: "\n").map(String.init)
			#expect(rows.count == 3)
			#expect(rows[0].hasPrefix("ID"))
			#expect(rows[1].hasPrefix("D1") && rows[1].contains("job"))
			#expect(rows[2].hasPrefix("D2"))

			cli.clear()
			let got7 = try await blocking { cli.run(["ls", "--json"]) }
			#expect(got7 == 0)
			let leases = try CryoJSON.decoder().decode([Lease].self, from: Data(cli.out.utf8))
			#expect(leases.map(\.id) == ["D1", "D2"])
			#expect(leases.map(\.ssh.host) == ["cryo-D1", "cryo-D2"])
		}
	}

	@Test func statusShowsTheBaysAndTheQueue() async throws {
		try await withDeck { fx, _ in
			let cli = try fx.cli()
			_ = try await blocking { cli.run(["lease"]) }
			cli.clear()
			let got8 = try await blocking { cli.run(["status"]) }
			#expect(got8 == 0)
			#expect(cli.out.contains("bay: version test, image fake-image, doctor ok"))
			#expect(cli.out.contains("capsule 0"))
			#expect(cli.out.contains("capsule 3"))
			#expect(cli.out.contains("bays:\n"))
			#expect(cli.out.contains("mini-1") && cli.out.contains("mini-2"))
			#expect(cli.out.contains("online"))
			#expect(cli.out.contains("1 thawed, 1 leased of 2"))
			#expect(cli.out.contains("queue: 0"))

			cli.clear()
			let got9 = try await blocking { cli.run(["status", "--json"]) }
			#expect(got9 == 0)
			let s = try CryoJSON.decoder().decode(Status.self, from: Data(cli.out.utf8))
			#expect(s.capsules.count == 4)
			#expect(s.bays?.map(\.name) == ["mini-1", "mini-2"])
		}
	}

	@Test func releaseRemovesTheLeaseHereAndOnItsBay() async throws {
		try await withDeck { fx, _ in
			let cli = try fx.cli()
			_ = try await blocking { cli.run(["lease"]) }
			_ = try await blocking { cli.run(["lease"]) }
			cli.clear()
			let got10 = try await blocking { cli.run(["release", "D2", "--save-cache"]) }
			#expect(got10 == 0)
			#expect(cli.out == "D2 released\n")
			#expect(fx.bays[1].releases == [FakeBay.Release(id: "L1", saveCache: true)])
			#expect(!pathExists(cli.path(".cryo/keys/D2")))
			#expect(pathExists(cli.path(".cryo/keys/D1")))
			#expect(blockIDs(cli.read(".cryo/ssh_config") ?? "") == ["D1"])
			cli.clear()
			_ = try await blocking { cli.run(["ls"]) }
			#expect(cli.out.contains("D1") && !cli.out.contains("D2"))
		}
	}

	@Test func releasingALeaseTheDeckLostFailsAndCleansUp() async throws {
		try await withDeck { fx, _ in
			let cli = try fx.cli()
			_ = try await blocking { cli.run(["lease"]) }
			fx.bays[0].loseLease("L1")
			cli.clear()
			let code = try await blocking { cli.run(["release", "D1"]) }
			#expect(code == 1)
			#expect(cli.err.contains("lease_lost"))
		}
	}

	@Test func aFolderIsRefusedWithAnExplanation() async throws {
		try await withDeck { fx, _ in
			let cli = try fx.cli()
			let code = try await blocking { cli.run(["lease", "--folder", "repo"]) }
			#expect(code != 0)
			#expect(cli.err.contains("--folder doesn't work through a deck"))
			#expect(cli.out.isEmpty)
			#expect(fx.bays.allSatisfy { $0.leases.isEmpty })
		}
	}

	@Test func aFullDeckGivesUpAtWaitZero() async throws {
		try await withDeck(bays: 1, capacity: 1) { fx, _ in
			let cli = try fx.cli()
			_ = try await blocking { cli.run(["lease"]) }
			cli.clear()
			let code = try await blocking { cli.run(["lease", "--wait", "0"]) }
			#expect(code != 0)
			#expect(cli.err.contains("no free capsule on any bay"))
		}
	}

	@Test func aWrongTokenIsRefused() async throws {
		try await withDeck(bays: 1) { fx, _ in
			let bad = try CLIRun(target: CryoTarget(endpoint: .tcp(host: "127.0.0.1", port: fx.port), token: "nope"))
			let code = try await blocking { bad.run(["status"]) }
			#expect(code == 1)
			#expect(bad.err.contains("unauthorized"))
		}
	}
}

import CryoAPI
import CryoClient
import CryoHTTP
import CryoServer
import FakeBay
import Foundation
import Testing

@testable import CryoDeck

/// A CRYO_HOME in a temp dir and captured output for `cryo deck …`.
final class CommandEnv: @unchecked Sendable {
	let home: String
	private let m = Monitor()
	private var _out = ""
	private var _err = ""

	init() throws { home = try makeTempDir() }
	deinit { try? FileManager.default.removeItem(atPath: home) }

	var out: String { m.withLock { _out } }
	var err: String { m.withLock { _err } }
	var paths: DeckPaths { DeckPaths.standard(environment: ["CRYO_HOME": home]) }
	var configText: String? { readTextFile(paths.config.path) }

	func run(_ args: [String], executable: String? = nil) -> Int32 {
		DeckCommand.main(
			args, environment: ["CRYO_HOME": home], executable: executable, version: "9.9.9",
			out: { [self] s in m.withLock { _out += s } }, err: { [self] s in m.withLock { _err += s } })
	}

	func clear() {
		m.withLock {
			_out = ""
			_err = ""
		}
	}
}

@Suite(.serialized) struct CommandTests {
	private func withBay(_ capacity: Int = 2, _ body: (FakeBay, BayEntry) throws -> Void) throws {
		let bay = FakeBay(capacity: capacity, tcp: true)
		try bay.start()
		defer { bay.stop() }
		try body(bay, BayEntry(name: "mini-1", url: "http://127.0.0.1:\(bay.tcpPort!)", token: bay.token!))
	}

	// MARK: help and usage

	@Test func noArgumentsAndHelpPrintTheHelp() throws {
		for args in [[], ["help"], ["--help"], ["-h"], ["add", "--help"], ["ls", "-h"], ["start", "--help"]] {
			let e = try CommandEnv()
			#expect(e.run(args) == 0, "\(args)")
			#expect(e.out == DeckCommand.help, "\(args)")
			#expect(e.err.isEmpty)
		}
		#expect(DeckCommand.help.contains("usage: cryo deck"))
		#expect(DeckCommand.help.contains("no TLS"))
		#expect(DeckCommand.help.contains("LAN or VPN"))
		for word in ["add", "rm", "ls", "token", "start", "install", "uninstall"] { #expect(DeckCommand.help.contains(word)) }
	}

	@Test func anUnknownCommandIsAUsageError() throws {
		let e = try CommandEnv()
		#expect(e.run(["frobnicate"]) == 2)
		#expect(e.err.contains("unknown command 'frobnicate'"))
		#expect(e.err.contains("usage: cryo deck"))
		#expect(e.out.isEmpty)
	}

	@Test func anUnknownOptionIsAUsageError() throws {
		let e = try CommandEnv()
		#expect(e.run(["ls", "--bogus"]) == 2)
		#expect(e.err == "cryo deck ls: unknown option --bogus\n")
		#expect(e.run(["token", "--rotate=yes"]) == 2)
		#expect(e.run(["start", "--listen"]) == 2)
		#expect(e.err.contains("--listen needs a value"))
	}

	@Test func listenAcceptsBothSpellings() {
		let a = try? DeckCommand.parseFlags(["--listen", ":7400"], values: ["listen"], bools: [])
		let b = try? DeckCommand.parseFlags(["--listen=:7401"], values: ["listen"], bools: [])
		#expect(a?.values["listen"] == ":7400")
		#expect(b?.values["listen"] == ":7401")
		let c = try? DeckCommand.parseFlags(["x", "--json", "y"], values: [], bools: ["json"])
		#expect(c?.positionals == ["x", "y"] && c?.bools == ["json"])
	}

	// MARK: add

	@Test func addChecksTheBayAnswersThenSavesIt() throws {
		try withBay { _, entry in
			let e = try CommandEnv()
			#expect(e.run(["add", "mini-1", entry.url, entry.token]) == 0)
			#expect(e.out.contains("mini-1 answers: version fake, 2 capsule(s)"))
			#expect(e.out.contains("added mini-1 to \(e.paths.config.path)"))
			#expect(!e.out.contains("restart the deck"))
			let config = try DeckConfig.load(e.paths.config)
			#expect(config.bays == [entry])
			#expect(fileMode(e.paths.config.path) == 0o600)
		}
	}

	@Test func addKeepsTheOtherBaysAndTheListenSetting() throws {
		try withBay { _, entry in
			let e = try CommandEnv()
			try DeckConfig(listen: ":7500", bays: [BayEntry(name: "old", url: "http://old:1", token: "t")]).save(e.paths.config)
			#expect(e.run(["add", "mini-1", entry.url, entry.token]) == 0)
			let config = try DeckConfig.load(e.paths.config)
			#expect(config.listen == ":7500")
			#expect(config.bays.map(\.name) == ["old", "mini-1"])
		}
	}

	@Test func addRefusesABayThatDoesNotAcceptTheToken() throws {
		try withBay { _, entry in
			let e = try CommandEnv()
			#expect(e.run(["add", "mini-1", entry.url, "wrong-token"]) == 1)
			#expect(e.err.contains("did not answer GET /v1/status with that token"))
			#expect(e.configText == nil)
		}
	}

	@Test func addRefusesABayThatIsNotThere() throws {
		let e = try CommandEnv()
		#expect(e.run(["add", "ghost", "http://127.0.0.1:\(try deadPort())", "t"]) == 1)
		#expect(e.err.contains("did not answer"))
		#expect(e.configText == nil)
	}

	@Test func addRefusesABadNameADuplicateAndTheWrongArguments() throws {
		try withBay { _, entry in
			let e = try CommandEnv()
			#expect(e.run(["add", "Mini_1", entry.url, entry.token]) == 2)
			#expect(e.err.contains("a bay name uses a-z, 0-9 and -"))
			#expect(e.run(["add", "mini-1"]) == 2)
			#expect(e.err.contains("usage: cryo deck add <name> <url> <token>"))
			#expect(e.run(["add", "mini-1", entry.url, entry.token, "extra"]) == 2)
			#expect(e.configText == nil)
			#expect(e.run(["add", "mini-1", entry.url, entry.token]) == 0)
			e.clear()
			#expect(e.run(["add", "mini-1", entry.url, entry.token]) == 1)
			#expect(e.err.contains("bay 'mini-1' exists"))
			#expect(try DeckConfig.load(e.paths.config).bays.count == 1)
		}
	}

	@Test func addAndRmSayWhenARunningDeckNeedsARestart() throws {
		try withBay { _, entry in
			let e = try CommandEnv()
			// Something listening on deck.sock stands in for a running deck.
			try makeDirs(e.home, mode: 0o700)
			let listener = try Listener.unix(path: e.paths.socket.path)
			defer { listener.close() }
			#expect(e.run(["add", "mini-1", entry.url, entry.token]) == 0)
			#expect(e.out.contains("restart the deck to apply"))
			e.clear()
			#expect(e.run(["rm", "mini-1"]) == 0)
			#expect(e.out.contains("restart the deck to apply"))
		}
	}

	// MARK: rm

	@Test func rmRemovesOneBay() throws {
		let e = try CommandEnv()
		try DeckConfig(bays: [
			BayEntry(name: "a", url: "http://a:1", token: "ta"), BayEntry(name: "b", url: "http://b:1", token: "tb"),
		]).save(e.paths.config)
		#expect(e.run(["rm", "a"]) == 0)
		#expect(e.out.contains("removed a; its leases are not touched"))
		#expect(try DeckConfig.load(e.paths.config).bays.map(\.name) == ["b"])
		#expect(!e.out.contains("restart the deck"))
	}

	@Test func rmOfAnUnknownBayAndWrongArgumentsFail() throws {
		let e = try CommandEnv()
		#expect(e.run(["rm", "nope"]) == 1)
		#expect(e.err.contains("no bay named 'nope'"))
		#expect(e.run(["rm"]) == 2)
		#expect(e.err.contains("usage: cryo deck rm <name>"))
		#expect(e.run(["rm", "a", "b"]) == 2)
	}

	// MARK: ls

	@Test func lsWithNoBaysSaysHowToAddOne() throws {
		let e = try CommandEnv()
		#expect(e.run(["ls"]) == 0)
		#expect(e.out == "no bays: cryo deck add <name> <url> <token>\n")
	}

	@Test func lsShowsOnlineAndOfflineBays() throws {
		try withBay { bay, entry in
			let e = try CommandEnv()
			let ghost = BayEntry(name: "ghost", url: "http://127.0.0.1:\(try deadPort())", token: "t")
			try DeckConfig(bays: [entry, ghost]).save(e.paths.config)
			// One capsule leased, one thawed.
			let c = CryoClient(target: CryoTarget(endpoint: .unix(path: bay.socketPath)))
			_ = try c.createLease(LeaseRequest())
			#expect(e.run(["ls"]) == 0)
			let lines = e.out.split(separator: "\n").map(String.init)
			#expect(lines.count == 3)
			#expect(lines[0].hasPrefix("bay") && lines[0].contains("state") && lines[0].contains("capsules") && lines[0].hasSuffix("url"))
			#expect(lines[1].contains("mini-1") && lines[1].contains("online") && lines[1].contains("1 thawed, 1 leased, 0 other"))
			#expect(lines[1].contains("fake-image") && lines[1].hasSuffix(entry.url))
			#expect(lines[2].contains("ghost") && lines[2].contains("offline") && lines[2].hasSuffix(ghost.url))
			#expect(!lines[2].contains("thawed"))
		}
	}

	@Test func lsJSONIsTheDeckBayList() throws {
		try withBay { _, entry in
			let e = try CommandEnv()
			let ghost = BayEntry(name: "ghost", url: "http://127.0.0.1:\(try deadPort())", token: "t")
			try DeckConfig(bays: [entry, ghost]).save(e.paths.config)
			#expect(e.run(["ls", "--json"]) == 0)
			let rows = try CryoJSON.decoder().decode([Status.DeckBay].self, from: Data(e.out.utf8))
			#expect(rows.map(\.name) == ["mini-1", "ghost"])
			#expect(rows.map(\.online) == [true, false])
			#expect(rows[0].capsules.count == 2 && rows[0].version == "fake" && rows[0].image == "fake-image")
			#expect(rows[1].capsules.isEmpty && rows[1].image == nil)
			#expect(!e.out.contains(entry.token))
		}
	}

	@Test func lsRejectsExtraArguments() throws {
		let e = try CommandEnv()
		#expect(e.run(["ls", "extra"]) == 2)
		#expect(e.err.contains("unexpected argument 'extra'"))
	}

	@Test func aBrokenConfigIsReportedWithItsLine() throws {
		let e = try CommandEnv()
		try makeDirs(e.home, mode: 0o700)
		try "garbage\n".write(toFile: e.paths.config.path, atomically: true, encoding: .utf8)
		#expect(e.run(["ls"]) == 1)
		#expect(e.err.contains("deck.toml line 1"))
		#expect(e.run(["add", "a", "http://x:1", "t"]) == 1)
	}

	// MARK: token

	@Test func tokenIsMadeOnFirstUseAndStaysTheSame() throws {
		let e = try CommandEnv()
		#expect(e.run(["token"]) == 0)
		let first = e.out.trimmingCharacters(in: .whitespacesAndNewlines)
		#expect(first.count == 64 && first.allSatisfy(\.isHexDigit))
		#expect(e.out.hasSuffix("\n"))
		#expect(fileMode(e.paths.token.path) == 0o600)
		#expect(readTextFile(e.paths.token.path)?.trimmingCharacters(in: .whitespacesAndNewlines) == first)
		e.clear()
		#expect(e.run(["token"]) == 0)
		#expect(e.out == first + "\n")
	}

	@Test func tokenRotateMakesANewOne() throws {
		let e = try CommandEnv()
		_ = e.run(["token"])
		let old = e.out
		e.clear()
		#expect(e.run(["token", "--rotate"]) == 0)
		#expect(e.out != old)
		#expect(e.out.trimmingCharacters(in: .whitespacesAndNewlines).count == 64)
		let saved = readTextFile(e.paths.token.path)
		#expect(saved == e.out)
		#expect(!e.out.contains("restart"))
	}

	@Test func tokenRotateSaysWhenARunningDeckNeedsARestart() throws {
		let e = try CommandEnv()
		try makeDirs(e.home, mode: 0o700)
		let listener = try Listener.unix(path: e.paths.socket.path)
		defer { listener.close() }
		#expect(e.run(["token", "--rotate"]) == 0)
		#expect(e.out.contains("restart the deck to apply"))
	}

	// MARK: start, install

	@Test func startRefusesABadListenValue() throws {
		let e = try CommandEnv()
		#expect(e.run(["start", "--listen", "nope"]) == 1)
		#expect(e.err.contains("--listen takes :PORT, PORT or HOST:PORT"))
		try DeckConfig(listen: "nope").save(e.paths.config)
		e.clear()
		#expect(e.run(["start"]) == 1)
		#expect(e.err.contains("--listen takes"))
	}

	@Test func installNeedsToKnowTheBinaryAndAGoodListenValue() throws {
		let e = try CommandEnv()
		#expect(e.run(["install"]) == 1)
		#expect(e.err.contains("can't tell where this cryo binary is"))
		e.clear()
		#expect(e.run(["install", "--listen", "nope"], executable: "/usr/local/bin/cryo") == 1)
		#expect(e.err.contains("--listen takes"))
		// Nothing was saved or installed.
		#expect(e.configText == nil)
		#expect(!pathExists(e.paths.token.path))
	}
}

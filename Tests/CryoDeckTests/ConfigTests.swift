import CryoClient
import CryoDeck
import Foundation
import Testing

@Suite struct DeckConfigTests {
	@Test func roundTrips() throws {
		let c = DeckConfig(listen: ":7400", bays: [BayEntry(name: "mini-1", url: "http://mini-1.lan:7477", token: "t\"1")])
		#expect(try DeckConfig.parse(c.text()) == c)
	}

	@Test func parsesTheDocumentedFile() throws {
		let text = """
			listen = ":7400"            # optional; flag wins
			[bay.mini-1]
			url = "http://mini-1.lan:7477"
			token = "abc"

			# a comment on its own line
			[bay.mini-2]
			url = "http://mini-2.lan:7477"   # trailing comment
			token = "def"
			"""
		let c = try DeckConfig.parse(text)
		#expect(c.listen == ":7400")
		#expect(
			c.bays == [
				BayEntry(name: "mini-1", url: "http://mini-1.lan:7477", token: "abc"),
				BayEntry(name: "mini-2", url: "http://mini-2.lan:7477", token: "def"),
			])
	}

	@Test func listenIsOptionalAndAnEmptyFileIsEmpty() throws {
		#expect(try DeckConfig.parse("") == DeckConfig())
		#expect(try DeckConfig.parse("# nothing here\n\n").listen == nil)
		#expect(DeckConfig.defaultListen == ":7400")
	}

	@Test func hashAndEqualsSignsInsideStringsSurvive() throws {
		let c = try DeckConfig.parse("[bay.a]\nurl = \"http://h/#x\"\ntoken = \"a=b#c\"\n")
		#expect(c.bays == [BayEntry(name: "a", url: "http://h/#x", token: "a=b#c")])
	}

	@Test func escapesRoundTrip() throws {
		let c = DeckConfig(bays: [BayEntry(name: "a", url: "http://h", token: #"back\slash "quoted""#)])
		let text = c.text()
		#expect(text.contains(#"token = "back\\slash \"quoted\"""#))
		#expect(try DeckConfig.parse(text) == c)
	}

	@Test func textKeepsBayOrderAndHasAHeaderComment() throws {
		let c = DeckConfig(bays: [BayEntry(name: "zz", url: "u1", token: "t1"), BayEntry(name: "aa", url: "u2", token: "t2")])
		let text = c.text()
		#expect(text.hasPrefix("# cryo deck"))
		#expect(!text.contains("listen"))
		let zz = try #require(text.range(of: "[bay.zz]"))
		let aa = try #require(text.range(of: "[bay.aa]"))
		#expect(zz.lowerBound < aa.lowerBound)
		#expect(try DeckConfig.parse(text).bays.map(\.name) == ["zz", "aa"])
	}

	@Test func bayLookupByName() {
		let c = DeckConfig(bays: [BayEntry(name: "a", url: "u", token: "t")])
		#expect(c.bay(named: "a")?.url == "u")
		#expect(c.bay(named: "b") == nil)
	}

	@Test func missingFileLoadsEmptyAndSaveMakesItPrivate() throws {
		let dir = try makeTempDir()
		defer { try? FileManager.default.removeItem(atPath: dir) }
		let url = URL(filePath: dir).appending(path: "sub/deck.toml")
		#expect(try DeckConfig.load(url) == DeckConfig())
		let c = DeckConfig(listen: "7401", bays: [BayEntry(name: "mini-1", url: "http://x:1", token: "secret")])
		try c.save(url)
		#expect(fileMode(url.path) == 0o600)
		#expect(fileMode(url.deletingLastPathComponent().path) == 0o700)
		#expect(try DeckConfig.load(url) == c)
	}

	@Test func saveTightensAWiderFile() throws {
		let dir = try makeTempDir()
		defer { try? FileManager.default.removeItem(atPath: dir) }
		let path = dir + "/deck.toml"
		try "old".write(toFile: path, atomically: true, encoding: .utf8)
		chmod(path, 0o644)
		try DeckConfig().save(URL(filePath: path))
		#expect(fileMode(path) == 0o600)
	}

	@Test func validBayNames() {
		for ok in ["a", "mini-1", "0", "a-b-c", "-"] { #expect(BayEntry.validName(ok), "\(ok)") }
		for bad in ["", "Mini", "mini_1", "mini 1", "mini.1", "é", "a/b"] { #expect(!BayEntry.validName(bad), "\(bad)") }
	}

	// MARK: rejections

	private func message(_ text: String) -> String? {
		do { _ = try DeckConfig.parse(text) } catch let e as DeckError { return e.description } catch { return "\(error)" }
		return nil
	}

	@Test func rejectsBadBayNames() {
		#expect(message("[bay.Mini]\nurl = \"u\"\ntoken = \"t\"\n")?.contains("bay names use a-z") == true)
		#expect(message("[bay.a b]\nurl = \"u\"\ntoken = \"t\"\n")?.contains("line 1") == true)
		#expect(message("[bay.]\n") != nil)
		#expect(message("[bay.a_b]\n")?.contains("a_b") == true)
	}

	@Test func rejectsOtherTablesAndMalformedHeaders() {
		#expect(message("[server]\n")?.contains("expected a [bay.<name>] table") == true)
		#expect(message("[bay.a\n") != nil)
		#expect(message("[[bay.a]]\n") != nil)
	}

	@Test func rejectsUnknownKeys() {
		#expect(message("port = \"1\"\n")?.contains("unknown key 'port'") == true)
		#expect(message("[bay.a]\nurl = \"u\"\ntoken = \"t\"\nweight = \"1\"\n")?.contains("unknown key 'weight' in [bay.a]") == true)
		// `listen` belongs before the tables.
		#expect(message("[bay.a]\nlisten = \":1\"\n")?.contains("unknown key 'listen'") == true)
	}

	@Test func rejectsMissingUrlOrToken() {
		#expect(message("[bay.a]\ntoken = \"t\"\n")?.contains("has no url") == true)
		#expect(message("[bay.a]\nurl = \"u\"\n")?.contains("has no token") == true)
		#expect(message("[bay.a]\nurl = \"u\"\ntoken = \"\"\n")?.contains("has no token") == true)
		// The last table is checked too, not only the ones followed by another table.
		#expect(message("[bay.a]\nurl = \"u\"\ntoken = \"t\"\n[bay.b]\nurl = \"u\"\n")?.contains("[bay.b] has no token") == true)
	}

	@Test func rejectsDuplicateBays() {
		let one = "[bay.a]\nurl = \"u\"\ntoken = \"t\"\n"
		#expect(message(one + one)?.contains("listed twice") == true)
	}

	@Test func rejectsValuesThatAreNotOneQuotedString() {
		#expect(message("listen = 7400\n")?.contains("must be a quoted string") == true)
		#expect(message("listen = \":7400\n")?.contains("quoted string") == true)
		#expect(message("listen = \"a\"b\"\n")?.contains("quoted string") == true)
		#expect(message("listen = \"a\\nb\"\n")?.contains("quoted string") == true)
		#expect(message("listen = \"a\" extra\n")?.contains("quoted string") == true)
		#expect(message("just words\n")?.contains("expected key") == true)
	}

	@Test func errorsNameTheLine() {
		#expect(message("listen = \":1\"\n\n\nbogus = \"x\"\n")?.contains("line 4") == true)
	}
}

@Suite struct DeckPathsTests {
	@Test func cryoHomeWins() {
		let p = DeckPaths.standard(environment: ["CRYO_HOME": "/srv/cryo", "HOME": "/home/x"])
		#expect(p.root.path == "/srv/cryo")
		#expect(p.config.path == "/srv/cryo/deck.toml")
		#expect(p.token.path == "/srv/cryo/deck-token")
		#expect(p.nextLease.path == "/srv/cryo/deck-next-lease")
		#expect(p.socket.path == "/srv/cryo/deck.sock")
		#expect(p.log.path == "/srv/cryo/deck.log")
	}

	@Test func otherwiseDotCryoUnderHome() {
		#expect(DeckPaths.standard(environment: ["HOME": "/home/x"]).root.path == "/home/x/.cryo")
		#expect(DeckPaths.standard(environment: ["CRYO_HOME": "", "HOME": "/home/x"]).root.path == "/home/x/.cryo")
	}
}

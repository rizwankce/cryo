import CryoAPI
import CryoClient
import CryoDeck
import CryoHTTP
import FakeBay
import Foundation

/// A time source and sleep tests control: `sleep` returns once `advance` has moved the clock far
/// enough (or at once when `autoAdvance` is set, which moves the clock by the slept time).
final class TestClock: @unchecked Sendable {
	private let m = Monitor()
	private var t: Double
	let autoAdvance: Bool

	init(start: Double = 1_000, autoAdvance: Bool = false) {
		t = start
		self.autoAdvance = autoAdvance
	}

	var now: Double { m.withLock { t } }

	func advance(_ s: Double) {
		m.withLock {
			t += s
			m.broadcast()
		}
	}

	/// Injected as the deck's `sleep`. Yields to other tasks so a waiting queue does not spin a core.
	func sleep(_ s: Double) async throws {
		if autoAdvance {
			advance(s)
			try await Task.sleep(for: .milliseconds(1))
			return
		}
		let until = now + s
		while now < until {
			try Task.checkCancellation()
			try await Task.sleep(for: .milliseconds(2))
		}
	}
}

/// N in-process `FakeBay`s (TCP with tokens, each with an echo server as its sshd) behind a deck
/// running in the same process. The deck is served on its unix socket and on 127.0.0.1.
final class DeckFixture: @unchecked Sendable {
	let bays: [FakeBay]
	let echos: [EchoServer]
	let entries: [BayEntry]
	let deck: Deck
	let deckToken = "deck-test-token"
	let socketDir: String
	let clock: TestClock?

	var socketPath: String { socketDir + "/deck.sock" }
	var port: Int { deck.tcpPort ?? 0 }
	var engine: DeckEngine { deck.engine }

	/// A client for the deck over TCP (token) or, with `viaSocket`, over its unix socket.
	func client(viaSocket: Bool = false) -> CryoClient {
		let target =
			viaSocket
			? CryoTarget(endpoint: .unix(path: socketPath))
			: CryoTarget(endpoint: .tcp(host: "127.0.0.1", port: port), token: deckToken)
		return CryoClient(target: target)
	}

	/// Starts `count` bays (`capacity` capsules each) and the deck, and polls once so every bay is
	/// online. `settings` and `clock` let a test control polling and waiting; the default settings
	/// poll every 0.2 s so queued requests move quickly.
	static func start(
		bays count: Int = 2, capacity: Int = 2, settings: DeckEngine.Settings? = nil, clock: TestClock? = nil,
		counter: LeaseCounter = LeaseCounter(), clientFactory: BayClientFactory? = nil
	) async throws -> DeckFixture {
		var bays: [FakeBay] = []
		var echos: [EchoServer] = []
		var entries: [BayEntry] = []
		for i in 0..<count {
			let bay = FakeBay(capacity: capacity, tcp: true)
			try bay.start()
			let echo = EchoServer()
			try echo.start()
			bay.sshdPort = echo.port
			bays.append(bay)
			echos.append(echo)
			entries.append(BayEntry(name: "mini-\(i + 1)", url: "http://127.0.0.1:\(bay.tcpPort!)", token: bay.token!))
		}
		var tuned = DeckEngine.Settings()
		tuned.pollInterval = 0.2
		tuned.queuePollInterval = 0.1
		let dir = try makeTempDir()
		let now: @Sendable () -> Double
		let sleep: @Sendable (Double) async throws -> Void
		if let clock {
			now = { clock.now }
			sleep = { try await clock.sleep($0) }
		} else {
			now = { nowSeconds() }
			sleep = { try await Task.sleep(for: .seconds($0)) }
		}
		let deck = Deck(
			bays: entries, socketPath: dir + "/deck.sock", token: "deck-test-token", version: "test", settings: settings ?? tuned,
			clientFactory: clientFactory ?? defaultBayClient, counter: counter,
			now: now, sleep: sleep)
		try await deck.start(listen: ("127.0.0.1", 0))
		return DeckFixture(bays: bays, echos: echos, entries: entries, deck: deck, socketDir: dir, clock: clock)
	}

	private init(bays: [FakeBay], echos: [EchoServer], entries: [BayEntry], deck: Deck, socketDir: String, clock: TestClock?) {
		self.bays = bays
		self.echos = echos
		self.entries = entries
		self.deck = deck
		self.socketDir = socketDir
		self.clock = clock
	}

	func stop() async {
		await deck.stop()
		for b in bays { b.stop() }
		for e in echos { e.stop() }
		rmdir(socketDir)
	}
}

func makeTempDir() throws -> String {
	var template = Array("/tmp/cryo-deck-test-XXXXXX".utf8CString)
	guard mkdtemp(&template) != nil else { throw SocketError("mkdtemp", errno: errno) }
	return String(decoding: template.dropLast().map { UInt8(bitPattern: $0) }, as: UTF8.self)
}

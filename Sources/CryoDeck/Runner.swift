import CryoAPI
import CryoClient
import CryoHTTP
import CryoServer
import Dispatch
import Foundation

/// A deck serving `/v1` on its unix socket and, with `listen`, on a token-protected TCP port.
/// `cryo deck start` runs one; tests run one in-process.
public final class Deck: @unchecked Sendable {
	public let engine: DeckEngine
	public let server: BayServer
	public let token: String?

	public init(
		bays: [BayEntry], socketPath: String, token: String?, version: String = "dev", settings: DeckEngine.Settings = .init(),
		clientFactory: @escaping BayClientFactory = defaultBayClient, counter: LeaseCounter = LeaseCounter(),
		now: @escaping @Sendable () -> Double = { nowSeconds() },
		sleep: @escaping @Sendable (Double) async throws -> Void = { try await Task.sleep(for: .seconds($0)) },
		event: @escaping @Sendable (String) -> Void = { _ in }
	) {
		engine = DeckEngine(
			bays: bays, version: version, settings: settings, clientFactory: clientFactory, counter: counter, now: now, sleep: sleep,
			event: event)
		server = BayServer(service: engine, socketPath: socketPath, log: ServerLog(subsystem: "dev.rizwan.cryo.deck", category: "server"))
		self.token = token
	}

	/// Polls the bays once (so status is true from the first request), then starts serving and polling.
	public func start(listen: (host: String, port: Int)?) async throws {
		await engine.pollOnce()
		try server.start(listen: listen, token: token)
		await engine.start()
	}

	public func stop() async {
		await engine.stop()
		server.stop()
	}

	/// The TCP port in use (with `listen` port 0 in tests).
	public var tcpPort: Int? { server.tcpPort }
}

/// `cryo deck start`.
enum DeckRun {
	static func run(listenFlag: String?, paths: DeckPaths, version: String, out: (String) -> Void) throws -> Int32 {
		let config = try DeckConfig.load(paths.config)
		let listenText = listenFlag ?? config.listen ?? DeckConfig.defaultListen
		guard let listen = BayServer.parseListen(listenText) else { throw DeckError("--listen takes :PORT, PORT or HOST:PORT") }
		if config.bays.isEmpty { out("no bays yet: add one with `cryo deck add <name> <url> <token>`, then restart the deck\n") }
		try makeDirs(paths.root.path, mode: 0o700)
		let token = try BearerToken.create(paths.token)
		let deck = Deck(
			bays: config.bays, socketPath: paths.socket.path, token: token, version: version,
			counter: LeaseCounter(file: paths.nextLease.path),
			event: { line in
				writeAll(1, "\(timestamp()) \(line)\n")
			})
		let box = StartBox()
		Task {
			do { try await deck.start(listen: listen) } catch { box.failure = "\(error)" }
			box.done.signal()
		}
		box.done.wait()
		if let failure = box.failure { throw DeckError(failure) }
		out("deck serving \(paths.socket.path) and \(listen.host):\(deck.tcpPort ?? listen.port) (no TLS: LAN or VPN only)\n")
		out("bays: \(config.bays.isEmpty ? "none" : config.bays.map(\.name).joined(separator: ", ")); clients' token: cryo deck token\n")
		out("Ctrl-C stops the deck; leases stay on their bays and answer lease_lost until the deck knows them again\n")

		let stop = DispatchSemaphore(value: 0)
		var sources: [DispatchSourceSignal] = []
		for sig in [SIGINT, SIGTERM] {
			signal(sig, SIG_IGN)
			let s = DispatchSource.makeSignalSource(signal: sig, queue: .global())
			s.setEventHandler { stop.signal() }
			s.resume()
			sources.append(s)
		}
		stop.wait()
		let finished = DispatchSemaphore(value: 0)
		Task {
			await deck.stop()
			finished.signal()
		}
		finished.wait()
		for s in sources { s.cancel() }
		return 0
	}

	private final class StartBox: @unchecked Sendable {
		let done = DispatchSemaphore(value: 0)
		var failure: String?
	}

	private static func timestamp() -> String {
		let f = ISO8601DateFormatter()
		f.formatOptions = [.withTime, .withColonSeparatorInTime]
		return f.string(from: Date())
	}
}

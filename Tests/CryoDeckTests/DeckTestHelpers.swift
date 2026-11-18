import CryoAPI
import CryoClient
import CryoDeck
import CryoHTTP
import CryoServer
import FakeBay
import Foundation

/// Runs a blocking call (a client call, a command) on its own thread, so the test never holds a
/// cooperative-pool thread that the deck needs.
func blocking<T: Sendable>(_ body: @escaping @Sendable () throws -> T) async throws -> T {
	try await withCheckedThrowingContinuation { cont in
		spawnThread { cont.resume(with: Result { try body() }) }
	}
}

/// Polls `cond` (real time) until it holds or `seconds` pass.
func waitUntil(_ seconds: Double = 5, _ cond: () async -> Bool) async -> Bool {
	let end = nowSeconds() + seconds
	while nowSeconds() < end {
		if await cond() { return true }
		try? await Task.sleep(for: .milliseconds(5))
	}
	return await cond()
}

/// Moves a `TestClock` forward in small steps (so queued requests see time pass) until `cond`
/// holds or `seconds` of real time pass.
func pump(_ clock: TestClock, step: Double = 0.1, seconds: Double = 5, until cond: () async -> Bool) async -> Bool {
	let end = nowSeconds() + seconds
	while nowSeconds() < end {
		if await cond() { return true }
		clock.advance(step)
		try? await Task.sleep(for: .milliseconds(5))
	}
	return await cond()
}

/// A flag a task sets when it is done.
final class Flag: @unchecked Sendable {
	private let m = Monitor()
	private var value = false
	var isSet: Bool { m.withLock { value } }
	func set() { m.withLock { value = true } }
}

struct APIFailure: Equatable {
	var status: Int
	var code: String
	var message: String
}

/// The API error a client call fails with, or nil when it succeeds or fails otherwise.
func apiFailure(_ body: () throws -> Void) -> APIFailure? {
	do { try body() } catch CryoClientError.api(let e, let status) { return APIFailure(status: status, code: e.code, message: e.message) } catch {}
	return nil
}

/// The `ServiceError` a direct engine call throws, or nil.
func serviceError<T>(_ body: () async throws -> T) async -> ServiceError? {
	do { _ = try await body() } catch let e as ServiceError { return e } catch {}
	return nil
}

/// A TCP port nothing listens on.
func deadPort() throws -> Int {
	let l = try Listener.tcp(host: "127.0.0.1", port: 0)
	let p = l.port!
	l.close()
	return p
}

// MARK: gates

/// Switches a test flips to make one bay fail or look different, without touching the FakeBay.
final class BayGate: @unchecked Sendable {
	private let m = Monitor()
	private var _failStatus = false
	private var _failCalls = false
	private var _failConnect = false
	private var _statusCalls = 0
	private var _image: String?

	/// `status` throws a transport error.
	var failStatus: Bool {
		get { m.withLock { _failStatus } }
		set { m.withLock { _failStatus = newValue } }
	}
	/// Every call but `status` throws a transport error.
	var failCalls: Bool {
		get { m.withLock { _failCalls } }
		set { m.withLock { _failCalls = newValue } }
	}
	/// Only `connect` throws a transport error.
	var failConnect: Bool {
		get { m.withLock { _failConnect } }
		set { m.withLock { _failConnect = newValue } }
	}
	/// Replaces `bay.image` in the status the deck sees.
	var image: String? {
		get { m.withLock { _image } }
		set { m.withLock { _image = newValue } }
	}
	var statusCalls: Int { m.withLock { _statusCalls } }
	func noteStatusCall() { m.withLock { _statusCalls += 1 } }
}

let gateDown = CryoClientError.transport(target: "gate", message: "down")

struct GatedBayClient: BayClient {
	let inner: any BayClient
	let gate: BayGate

	func status(timeout: Int) throws -> Status {
		gate.noteStatusCall()
		if gate.failStatus { throw gateDown }
		var s = try inner.status(timeout: timeout)
		if let image = gate.image { s.bay.image = image }
		return s
	}
	func listLeases() throws -> [Lease] {
		if gate.failCalls { throw gateDown }
		return try inner.listLeases()
	}
	func createLease(_ request: LeaseRequest) throws -> Lease {
		if gate.failCalls { throw gateDown }
		return try inner.createLease(request)
	}
	func lease(_ id: String) throws -> Lease {
		if gate.failCalls { throw gateDown }
		return try inner.lease(id)
	}
	func renew(_ id: String) throws -> RenewResponse {
		if gate.failCalls { throw gateDown }
		return try inner.renew(id)
	}
	func release(_ id: String, saveCache: Bool) throws {
		if gate.failCalls { throw gateDown }
		try inner.release(id, saveCache: saveCache)
	}
	func connect(_ id: String) throws -> ByteStream {
		if gate.failCalls || gate.failConnect { throw gateDown }
		return try inner.connect(id)
	}
}

/// One gate per bay (`mini-1` is index 0).
final class Gates: @unchecked Sendable {
	let byName: [String: BayGate]
	let count: Int

	init(count: Int) {
		self.count = count
		byName = Dictionary(uniqueKeysWithValues: (0..<count).map { ("mini-\($0 + 1)", BayGate()) })
	}

	subscript(i: Int) -> BayGate { byName["mini-\(i + 1)"]! }

	var factory: BayClientFactory {
		let map = byName
		return { entry in GatedBayClient(inner: try defaultBayClient(entry), gate: map[entry.name] ?? BayGate()) }
	}

	/// Waits until the deck has polled every bay twice: once in `Deck.start`, once when the poll
	/// loop starts. After that a manual clock keeps the loop parked, so tests poll by hand.
	func settle() async {
		_ = await waitUntil { (0..<count).allSatisfy { self[$0].statusCalls >= 2 } }
	}
}

// MARK: fixtures

/// A deck with real time and a fast poll (0.2 s); every bay's client is gated.
func withDeck(
	bays: Int = 2, capacity: Int = 2, counter: LeaseCounter = LeaseCounter(),
	pollInterval: Double = 0.2,
	_ body: (DeckFixture, Gates) async throws -> Void
) async throws {
	var settings = DeckEngine.Settings()
	settings.pollInterval = pollInterval
	settings.queuePollInterval = 0.1
	let gates = Gates(count: bays)
	let fx = try await DeckFixture.start(
		bays: bays, capacity: capacity, settings: settings, counter: counter, clientFactory: gates.factory)
	do { try await body(fx, gates) } catch {
		await fx.stop()
		throw error
	}
	await fx.stop()
}

/// A deck on a manual clock: nothing waits or polls unless the test moves the clock or calls
/// `engine.pollOnce()`. Default settings (5 s poll, two failures to go offline).
func withManualDeck(
	bays: Int = 2, capacity: Int = 2, counter: LeaseCounter = LeaseCounter(),
	settings: DeckEngine.Settings = DeckEngine.Settings(),
	_ body: (DeckFixture, Gates) async throws -> Void
) async throws {
	let gates = Gates(count: bays)
	let fx = try await DeckFixture.start(
		bays: bays, capacity: capacity, settings: settings, clock: TestClock(), counter: counter, clientFactory: gates.factory)
	await gates.settle()
	do { try await body(fx, gates) } catch {
		await fx.stop()
		throw error
	}
	await fx.stop()
}

extension DeckFixture {
	/// `POST /v1/leases` through the deck.
	func lease(_ request: LeaseRequest = LeaseRequest(), viaSocket: Bool = false) async throws -> Lease {
		let c = client(viaSocket: viaSocket)
		return try await blocking { try c.createLease(request) }
	}

	/// The API failure a call through the deck ends in.
	func failure(viaSocket: Bool = false, _ body: @escaping @Sendable (CryoClient) throws -> Void) async throws -> APIFailure? {
		let c = client(viaSocket: viaSocket)
		return try await blocking { apiFailure { try body(c) } }
	}

	/// A client straight to bay `i` (not through the deck).
	func bayClient(_ i: Int) -> CryoClient {
		CryoClient(target: CryoTarget(endpoint: .unix(path: bays[i].socketPath)))
	}

	/// The engine's lease, for tests that need no HTTP.
	func engineLease(_ request: LeaseRequest = LeaseRequest()) async throws -> Lease {
		try await engine.createLease(request, viaNetwork: false)
	}
}

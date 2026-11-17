import CryoAPI
import CryoHTTP
import FakeBay
import Foundation
import Testing

@testable import CryoClient
@testable import CryoServer

/// In-memory service: enough behavior to drive every route.
final class FakeService: BayService, @unchecked Sendable {
	private let m = Monitor()
	private var table: [String: Lease] = [:]
	private var next = 1
	private var _opened = 0
	private var _closed = 0
	private var _viaNetwork: [Bool] = []
	private var _cancelled = false
	private var _lastSaveCache: Bool?

	/// Port `connectTarget` reports (an EchoServer, or a dead port).
	var sshdPort = 1
	/// `createLease` sleeps this long first (cancellably).
	var createDelayMs = 0
	var createError: ServiceError?

	var opened: Int { m.withLock { _opened } }
	var closed: Int { m.withLock { _closed } }
	var viaNetwork: [Bool] { m.withLock { _viaNetwork } }
	var cancelled: Bool { m.withLock { _cancelled } }
	var lastSaveCache: Bool? { m.withLock { _lastSaveCache } }

	func createLease(_ request: LeaseRequest, viaNetwork: Bool) async throws -> Lease {
		m.withLock { _viaNetwork.append(viaNetwork) }
		if createDelayMs > 0 {
			do { try await Task.sleep(for: .milliseconds(createDelayMs)) } catch {
				m.withLock { _cancelled = true }
				throw error
			}
		}
		if let createError { throw createError }
		return m.withLock {
			let id = "L\(next)"
			next += 1
			let now = Date(timeIntervalSince1970: 1_800_000_000)
			let l = Lease(
				id: id, name: request.name, capsule: 0, state: "leased", createdAt: now, renewBy: now.addingTimeInterval(300),
				expiresAt: now.addingTimeInterval(86400), cache: request.cache, idleS: request.idleS ?? 3600,
				ssh: SSHInfo(user: "cryo", host: "cryo-\(id)", key: "k", config: "c"))
			table[id] = l
			return l
		}
	}

	func lease(_ id: String) async throws -> Lease {
		if id == "lost" { throw ServiceError.leaseLost(id, "capsule crashed") }
		guard let l = m.withLock({ table[id] }) else { throw ServiceError.notFound(id) }
		return l
	}

	func leases() async -> [Lease] { m.withLock { table.values.sorted { $0.id < $1.id } } }

	func renew(_ id: String) async throws -> RenewResponse {
		guard m.withLock({ table[id] }) != nil else { throw ServiceError.notFound(id) }
		return RenewResponse(renewBy: Date(timeIntervalSince1970: 1_800_000_300))
	}

	func release(_ id: String, saveCache: Bool) async throws {
		try m.withLock {
			guard table.removeValue(forKey: id) != nil else { throw ServiceError.notFound(id) }
			_lastSaveCache = saveCache
		}
	}

	func status() async -> Status {
		Status(bay: .init(version: "t", image: "img", doctor: Status.doctorOK), capsules: [.init(n: 0, state: "thawed")], queue: 0)
	}

	func doctor() async -> [DoctorCheck] { [DoctorCheck(check: "host unlocked", ok: true)] }

	func connectTarget(_ id: String) async throws -> (host: String, port: Int) {
		if id == "boom" { throw NSError(domain: "x", code: 1) }
		guard m.withLock({ table[id] }) != nil else { throw ServiceError.notFound(id) }
		return ("127.0.0.1", sshdPort)
	}

	/// The lease ends without a release (idle or max length).
	func expire(_ id: String) { m.withLock { _ = table.removeValue(forKey: id) } }

	func connectionOpened(_ id: String) async { m.withLock { _opened += 1 } }
	func connectionClosed(_ id: String) async { m.withLock { _closed += 1 } }
}

/// Short path: unix socket paths top out around 104 bytes.
func shortTempPaths() throws -> TestPaths {
	var template = Array("/tmp/cryo-srv-XXXXXX".utf8CString)
	guard mkdtemp(&template) != nil else { throw SocketError("mkdtemp", errno: errno) }
	let d = String(decoding: template.dropLast().map { UInt8(bitPattern: $0) }, as: UTF8.self)
	return TestPaths(root: URL(filePath: d, directoryHint: .isDirectory))
}

/// A temp directory holding the server's socket and a token file.
struct TestPaths {
	let root: URL
	var socket: URL { root.appending(path: "bay.sock") }
	var token: URL { root.appending(path: "token") }
}

/// A port nothing listens on.
func deadPort() throws -> Int {
	let l = try Listener.tcp(host: "127.0.0.1", port: 0)
	let p = l.port!
	l.close()
	return p
}

func eventually(_ seconds: Double = 3, _ cond: () -> Bool) -> Bool {
	let end = nowSeconds() + seconds
	while nowSeconds() < end {
		if cond() { return true }
		usleep(10_000)
	}
	return cond()
}

struct Harness {
	let paths: TestPaths
	let service: FakeService
	let server: BayServer
	var unix: CryoClient { CryoClient(target: CryoTarget(endpoint: .unix(path: paths.socket.path))) }
	func tcp(token: String?) -> CryoClient {
		CryoClient(target: CryoTarget(endpoint: .tcp(host: "127.0.0.1", port: server.tcpPort!), token: token))
	}
	func cleanup() {
		server.stop()
		try? FileManager.default.removeItem(at: paths.root)
	}
}

func withServer<T>(listen: Bool = false, token: String? = "secret-token", _ body: (Harness) throws -> T) throws -> T {
	let paths = try shortTempPaths()
	let service = FakeService()
	let server = BayServer(service: service, socketPath: paths.socket.path)
	try server.start(listen: listen ? ("127.0.0.1", 0) : nil, token: token)
	let h = Harness(paths: paths, service: service, server: server)
	defer { h.cleanup() }
	return try body(h)
}

func apiError(_ body: () throws -> Void) -> (code: String, status: Int)? {
	do { try body() } catch CryoClientError.api(let e, let status) { return (e.code, status) } catch {}
	return nil
}

/// One raw request on a fresh connection.
func raw(_ socketPath: String, _ method: String, _ target: String, headers: [String: String] = [:], body: String = "") throws -> HTTPResponse {
	let s = try Socket.connectUnix(path: socketPath)
	defer { s.close() }
	s.setTimeouts(receive: 5)
	var h = HTTPHeaders()
	for (k, v) in headers { h[k] = v }
	try s.writeAll(HTTPRequest(method: method, target: target, headers: h, body: Array(body.utf8)).serialized())
	return try HTTPWire.readResponse(from: s)
}

// Serialized: the tests block their own (cooperative pool) thread on client calls, while the server
// needs pool threads to run the async service. Many in parallel would starve the pool.
@Suite(.serialized) struct ServerTests {
	@Test func unixRoundTripForEveryRoute() throws {
		try withServer { h in
			let c = h.unix
			let l = try c.createLease(LeaseRequest(cache: "npm", name: "job", idleS: 300))
			#expect(l.id == "L1")
			#expect(l.name == "job")
			#expect(l.cache == "npm")
			#expect(l.idleS == 300)
			#expect(try c.lease(l.id) == l)
			#expect(try c.listLeases() == [l])
			#expect(try c.renew(l.id).renewBy == Date(timeIntervalSince1970: 1_800_000_300))
			#expect(try c.status().bay.version == "t")
			#expect(try c.doctor() == [DoctorCheck(check: "host unlocked", ok: true)])
			try c.release(l.id, saveCache: true)
			#expect(h.service.lastSaveCache == true)
			#expect(try c.listLeases().isEmpty)
			#expect(h.service.viaNetwork == [false])
			// Release without the flag.
			let l2 = try c.createLease(LeaseRequest())
			try c.release(l2.id)
			#expect(h.service.lastSaveCache == false)
		}
	}

	@Test func statusCodesAndVersionHeader() throws {
		try withServer { h in
			let p = h.paths.socket.path
			let created = try raw(p, "POST", "/v1/leases")
			#expect(created.status == 201)
			#expect(created.headers[apiVersionHeader] == "1")
			#expect(created.headers["Content-Type"] == "application/json")
			let released = try raw(p, "DELETE", "/v1/leases/L1")
			#expect(released.status == 204)
			#expect(released.headers[apiVersionHeader] == "1")
			#expect(try raw(p, "GET", "/v1/status").status == 200)
		}
	}

	@Test func badRequests() throws {
		try withServer { h in
			let p = h.paths.socket.path
			func code(_ r: HTTPResponse) throws -> String { try CryoJSON.decoder().decode(APIError.self, from: Data(r.body)).code }
			let badJSON = try raw(p, "POST", "/v1/leases", body: "{nope")
			#expect(badJSON.status == 400)
			#expect(try code(badJSON) == "bad_request")
			let unknown = try raw(p, "GET", "/v1/nothing")
			#expect(unknown.status == 404)
			#expect(try code(unknown) == "not_found")
			#expect(try raw(p, "GET", "/elsewhere").status == 404)
			let wrong = try raw(p, "PUT", "/v1/leases")
			#expect(wrong.status == 405)
			#expect(try code(wrong) == "bad_request")
			#expect(try raw(p, "POST", "/v1/status").status == 405)
			#expect(try raw(p, "GET", "/v1/leases/L1/renew").status == 405)
			#expect(wrong.headers[apiVersionHeader] == "1")
		}
	}

	@Test func serviceErrorsKeepStatusAndCode() throws {
		try withServer { h in
			let c = h.unix
			let notFound = apiError { _ = try c.lease("nope") }
			#expect(notFound?.status == 404 && notFound?.code == "not_found")
			let lost = apiError { _ = try c.lease("lost") }
			#expect(lost?.status == 410 && lost?.code == "lease_lost")
			h.service.createError = .noCapacity("no free capsule")
			let cap = apiError { _ = try c.createLease(LeaseRequest(waitS: 0)) }
			#expect(cap?.status == 503 && cap?.code == "no_capacity")
			let gone = apiError { try c.release("nope") }
			#expect(gone?.status == 404)
			h.service.createError = ServiceError(500, "internal", "x")
			#expect(apiError { _ = try c.createLease(LeaseRequest()) }?.status == 500)
		}
	}

	@Test func unexpectedErrorsAreInternal() throws {
		try withServer { h in
			let r = try raw(h.paths.socket.path, "POST", "/v1/leases/boom/connect", headers: ["Connection": "Upgrade", "Upgrade": "cryo-ssh"])
			#expect(r.status == 500)
			let e = try CryoJSON.decoder().decode(APIError.self, from: Data(r.body))
			#expect(e.code == "internal")
		}
	}

	@Test func tcpNeedsTheToken() throws {
		try withServer(listen: true) { h in
			let ok = h.tcp(token: "secret-token")
			let l = try ok.createLease(LeaseRequest())
			#expect(h.service.viaNetwork == [true])
			#expect(try ok.status().bay.image == "img")
			try ok.release(l.id)
			#expect(apiError { _ = try h.tcp(token: nil).status() }?.status == 401)
			let wrong = apiError { _ = try h.tcp(token: "secret-tokeX").status() }
			#expect(wrong?.status == 401 && wrong?.code == "unauthorized")
			#expect(apiError { _ = try h.tcp(token: "secret").status() }?.status == 401)
			// The unix socket needs no token.
			#expect(try h.unix.status().bay.image == "img")
		}
	}

	@Test func adminRoutes() throws {
		try withServer(listen: true) { h in
			let p = h.paths.socket.path
			for (method, path) in [("POST", "/v1/drain"), ("POST", "/v1/undrain"), ("POST", "/v1/image"), ("POST", "/v1/capsules/1/refreeze")] {
				let r = try raw(p, method, path, body: "{}")
				#expect(r.status == 501, "\(path)")
				#expect(try CryoJSON.decoder().decode(APIError.self, from: Data(r.body)).code == "not_implemented")
				// Over TCP, even with the right token.
				let s = try Socket.connectTCP(host: "127.0.0.1", port: h.server.tcpPort!)
				defer { s.close() }
				var hd = HTTPHeaders()
				hd["Authorization"] = "Bearer secret-token"
				try s.writeAll(HTTPRequest(method: method, target: path, headers: hd, body: Array("{}".utf8)).serialized())
				let t = try HTTPWire.readResponse(from: s)
				#expect(t.status == 403, "\(path)")
				#expect(try CryoJSON.decoder().decode(APIError.self, from: Data(t.body)).code == "unauthorized")
			}
		}
	}

	@Test func tcpWithoutTokenIsRefusedAtStart() throws {
		let paths = try shortTempPaths()
		defer { try? FileManager.default.removeItem(at: paths.root) }
		let server = BayServer(service: FakeService(), socketPath: paths.socket.path)
		#expect(throws: ServerError.self) { try server.start(listen: ("127.0.0.1", 0), token: nil) }
		#expect(throws: ServerError.self) { try server.start(listen: ("127.0.0.1", 0), token: "") }
		#expect(!FileManager.default.fileExists(atPath: paths.socket.path))
	}

	@Test func socketIsOwnerOnly() throws {
		try withServer { h in
			var st = stat()
			#expect(stat(h.paths.socket.path, &st) == 0)
			#expect(st.st_mode & 0o777 == 0o600)
		}
	}

	@Test func staleSocketFileIsReplaced() throws {
		let paths = try shortTempPaths()
		defer { try? FileManager.default.removeItem(at: paths.root) }
		// A socket file with nobody listening: bind, then close without unlinking.
		let fd = socket(AF_UNIX, SOCK_STREAM, 0)
		var addr = sockaddr_un()
		addr.sun_family = sa_family_t(AF_UNIX)
		let bytes = Array(paths.socket.path.utf8)
		withUnsafeMutableBytes(of: &addr.sun_path) { r in for (i, b) in bytes.enumerated() { r[i] = b } }
		_ = withUnsafePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) } }
		close(fd)
		#expect(FileManager.default.fileExists(atPath: paths.socket.path))
		let server = BayServer(service: FakeService(), socketPath: paths.socket.path)
		try server.start(listen: nil, token: nil)
		defer { server.stop() }
		let c = CryoClient(target: CryoTarget(endpoint: .unix(path: paths.socket.path)))
		#expect(try c.status().bay.image == "img")
	}

	@Test func secondServerOnTheSameSocketRefuses() throws {
		try withServer { h in
			let other = BayServer(service: FakeService(), socketPath: h.paths.socket.path)
			do {
				try other.start(listen: nil, token: nil)
				Issue.record("second start should fail")
			} catch {
				#expect("\(error)".contains("another bay is running"))
			}
			// The first one is untouched.
			let status = try h.unix.status()
			#expect(status.bay.image == "img")
		}
	}

	@Test func restartAfterStop() throws {
		let paths = try shortTempPaths()
		defer { try? FileManager.default.removeItem(at: paths.root) }
		let service = FakeService()
		let a = BayServer(service: service, socketPath: paths.socket.path)
		try a.start(listen: nil, token: nil)
		a.stop()
		let b = BayServer(service: service, socketPath: paths.socket.path)
		try b.start(listen: nil, token: nil)
		defer { b.stop() }
		let c = CryoClient(target: CryoTarget(endpoint: .unix(path: paths.socket.path)))
		#expect(try c.status().bay.version == "t")
	}

	@Test func oldClientsGetUpgradeRequired() throws {
		try withServer { h in
			#expect(try raw(h.paths.socket.path, "GET", "/v1/status").status == 200)
			h.server.minimumClientVersion = 2
			let r = try raw(h.paths.socket.path, "GET", "/v1/status", headers: [apiVersionHeader: "1"])
			#expect(r.status == 426)
			#expect(try CryoJSON.decoder().decode(APIError.self, from: Data(r.body)).code == "upgrade_required")
			#expect(r.headers[apiVersionHeader] == "1")
		}
	}

	@Test func slowCreateDoesNotBlockStatus() throws {
		try withServer { h in
			h.service.createDelayMs = 1500
			let client = h.unix
			let slow = Monitor()
			nonisolated(unsafe) var finished = false
			spawnThread {
				_ = try? client.createLease(LeaseRequest())
				slow.withLock {
					finished = true
					slow.broadcast()
				}
			}
			usleep(200_000)
			let t0 = nowSeconds()
			let status = try client.status()
			let leases = try client.listLeases()
			#expect(status.bay.image == "img")
			#expect(leases.isEmpty)
			#expect(nowSeconds() - t0 < 1.0)
			#expect(!slow.withLock { finished })
			#expect(eventually(5) { slow.withLock { finished } })
		}
	}

	@Test func manyConcurrentRequests() throws {
		try withServer { h in
			let client = h.unix
			let m = Monitor()
			nonisolated(unsafe) var done = 0
			for _ in 0..<20 {
				spawnThread {
					_ = try? client.status()
					m.withLock { done += 1 }
				}
			}
			#expect(eventually { m.withLock { done } == 20 })
		}
	}

	@Test func disconnectedWaiterCancelsTheLeaseRequest() throws {
		try withServer { h in
			h.service.createDelayMs = 10_000
			let s = try Socket.connectUnix(path: h.paths.socket.path)
			try s.writeAll(HTTPRequest(method: "POST", target: "/v1/leases").serialized())
			usleep(300_000)
			s.close()
			#expect(eventually(3) { h.service.cancelled })
		}
	}

	// MARK: connect

	@Test func connectPipesBytesAndCountsOnce() throws {
		let echo = EchoServer()
		try echo.start()
		defer { echo.stop() }
		try withServer { h in
			h.service.sshdPort = echo.port
			let l = try h.unix.createLease(LeaseRequest())
			let stream = try h.unix.connect(l.id)
			#expect(eventually { h.service.opened == 1 })
			#expect(h.service.closed == 0)
			let payload = [UInt8]((0..<200_000).map { UInt8($0 % 251) })
			// Write on a thread: the echo can fill the socket buffers before we start reading.
			let writer = Monitor()
			nonisolated(unsafe) var wrote = false
			spawnThread {
				try? stream.writeAll(payload)
				stream.shutdownWrite()  // half-close: the echo must still deliver everything
				writer.withLock {
					wrote = true
					writer.broadcast()
				}
			}
			var got: [UInt8] = []
			stream.setTimeouts(receive: 10)
			while true {
				let part = try stream.read()
				if part.isEmpty { break }
				got += part
			}
			#expect(got == payload)
			#expect(eventually { writer.withLock { wrote } })
			stream.close()
			#expect(eventually { h.service.closed == 1 })
			usleep(200_000)
			#expect(h.service.opened == 1)
			#expect(h.service.closed == 1)
			// The lease is still there: closing the stream is not a release.
			#expect(try h.unix.lease(l.id) == l)
		}
	}

	/// The bay runs for days: hundreds of lease, connect, release cycles must leave no socket open
	/// and every connect counted closed (an open count keeps a lease from idling out).
	@Test func hundredsOfLeaseCyclesLeakNothing() throws {
		let echo = EchoServer()
		try echo.start()
		defer { echo.stop() }
		try withServer { h in
			h.service.sshdPort = echo.port
			let fdsBefore = (try? FileManager.default.contentsOfDirectory(atPath: "/dev/fd").count) ?? 0
			let cycles = 300
			for _ in 0..<cycles {
				let l = try h.unix.createLease(LeaseRequest())
				let stream = try h.unix.connect(l.id)
				try stream.writeAll([7])
				#expect(try stream.readExactly(1) == [7])
				stream.close()
				try h.unix.release(l.id)
			}
			#expect(eventually(5) { h.service.closed == cycles })
			#expect(h.service.opened == cycles)
			#expect(try h.unix.listLeases().isEmpty)
			#expect(eventually(5) { ((try? FileManager.default.contentsOfDirectory(atPath: "/dev/fd").count) ?? 0) <= fdsBefore + 4 })
		}
	}

	@Test func connectClosedOnceWhenClientJustHangsUp() throws {
		let echo = EchoServer()
		try echo.start()
		defer { echo.stop() }
		try withServer { h in
			h.service.sshdPort = echo.port
			let l = try h.unix.createLease(LeaseRequest())
			let stream = try h.unix.connect(l.id)
			try stream.writeAll(Array("hi".utf8))
			#expect(try stream.readExactly(2) == Array("hi".utf8))
			stream.close()
			#expect(eventually { h.service.closed == 1 })
			usleep(200_000)
			#expect(h.service.opened == 1 && h.service.closed == 1)
		}
	}

	@Test func connectOverTCPWithToken() throws {
		let echo = EchoServer()
		try echo.start()
		defer { echo.stop() }
		try withServer(listen: true) { h in
			h.service.sshdPort = echo.port
			let l = try h.unix.createLease(LeaseRequest())
			#expect(apiError { _ = try h.tcp(token: nil).connect(l.id) }?.status == 401)
			let stream = try h.tcp(token: "secret-token").connect(l.id)
			try stream.writeAll(Array("ping".utf8))
			#expect(try stream.readExactly(4) == Array("ping".utf8))
			stream.close()
			#expect(eventually { h.service.closed == 1 })
		}
	}

	@Test func connectToUnreachableTargetIs503() throws {
		try withServer { h in
			h.service.sshdPort = try deadPort()
			let l = try h.unix.createLease(LeaseRequest())
			let e = apiError { _ = try h.unix.connect(l.id) }
			#expect(e?.status == 503 && e?.code == "capsule_unreachable")
			#expect(h.service.opened == 0 && h.service.closed == 0)
		}
	}

	@Test func connectNeedsTheUpgradeHeaders() throws {
		try withServer { h in
			let l = try h.unix.createLease(LeaseRequest())
			let p = h.paths.socket.path
			#expect(try raw(p, "POST", "/v1/leases/\(l.id)/connect").status == 400)
			#expect(try raw(p, "POST", "/v1/leases/\(l.id)/connect", headers: ["Upgrade": "cryo-ssh"]).status == 400)
			#expect(try raw(p, "POST", "/v1/leases/\(l.id)/connect", headers: ["Connection": "Upgrade", "Upgrade": "websocket"]).status == 400)
			#expect(try raw(p, "GET", "/v1/leases/\(l.id)/connect").status == 405)
			let e = apiError { _ = try h.unix.connect("nope") }
			#expect(e?.status == 404)
		}
	}

	/// A stopped VM sends no FIN, so the bay must end the stream itself when the lease ends.
	@Test func leaseEndClosesItsStreams() throws {
		let echo = EchoServer()
		try echo.start()
		defer { echo.stop() }
		try withServer { h in
			h.service.sshdPort = echo.port
			h.server.leaseCheckInterval = 0.1
			let released = try h.unix.createLease(LeaseRequest())
			let expired = try h.unix.createLease(LeaseRequest())
			let kept = try h.unix.createLease(LeaseRequest())
			var streams: [Socket] = []
			for l in [released, expired, kept] {
				let s = try h.unix.connect(l.id)
				try s.writeAll([1])
				#expect(try s.readExactly(1) == [1])
				s.setTimeouts(receive: 3)
				streams.append(s)
			}
			defer { for s in streams { s.close() } }
			try h.unix.release(released.id)
			#expect(try streams[0].read().isEmpty)
			h.service.expire(expired.id)
			#expect(try streams[1].read().isEmpty)
			#expect(eventually { h.service.closed == 2 })
			// The other lease's stream still flows.
			try streams[2].writeAll([2])
			#expect(try streams[2].readExactly(1) == [2])
			#expect(h.service.closed == 2)
		}
	}

	@Test func stopClosesOpenStreams() throws {
		let echo = EchoServer()
		try echo.start()
		defer { echo.stop() }
		try withServer { h in
			h.service.sshdPort = echo.port
			let l = try h.unix.createLease(LeaseRequest())
			let stream = try h.unix.connect(l.id)
			try stream.writeAll(Array("a".utf8))
			_ = try stream.readExactly(1)
			h.server.stop()
			stream.setTimeouts(receive: 3)
			#expect(try stream.read().isEmpty)
			#expect(eventually { h.service.closed == 1 })
		}
	}
}

@Suite struct TokenAndListenTests {
	@Test func createsLoadsAndRotates() throws {
		let paths = try shortTempPaths()
		defer { try? FileManager.default.removeItem(at: paths.root) }
		#expect(BearerToken.load(paths.token) == nil)
		let t = try BearerToken.create(paths.token)
		#expect(t.count == 64)
		#expect(t.allSatisfy { $0.isHexDigit })
		#expect(BearerToken.load(paths.token) == t)
		#expect(try BearerToken.create(paths.token) == t)
		var st = stat()
		#expect(stat(paths.token.path, &st) == 0)
		#expect(st.st_mode & 0o777 == 0o600)
		let r = try BearerToken.create(paths.token, rotate: true)
		#expect(r != t && r.count == 64)
		#expect(BearerToken.load(paths.token) == r)
		#expect(stat(paths.token.path, &st) == 0 && st.st_mode & 0o777 == 0o600)
	}

	@Test func parseListen() {
		#expect(BayServer.parseListen(":7477")?.host == "0.0.0.0")
		#expect(BayServer.parseListen(":7477")?.port == 7477)
		#expect(BayServer.parseListen("7477")?.port == 7477)
		#expect(BayServer.parseListen("10.0.0.2:80")?.host == "10.0.0.2")
		#expect(BayServer.parseListen("x:y") == nil)
	}

	@Test func constantTimeCompare() {
		#expect(constantTimeEqual("abc", "abc"))
		#expect(!constantTimeEqual("abc", "abd"))
		#expect(!constantTimeEqual("abc", "abcd"))
		#expect(!constantTimeEqual("", "a"))
		#expect(constantTimeEqual("", ""))
	}
}

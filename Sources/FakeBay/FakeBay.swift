import CryoAPI
import CryoHTTP

#if canImport(FoundationEssentials)
	import FoundationEssentials
#else
	import Foundation
#endif

/// In-process stand-in for a bay: implements /v1 on a unix socket (no auth) and optionally on
/// TCP 127.0.0.1 (bearer token required). One thread per connection.
public final class FakeBay: @unchecked Sendable {
	public struct Release: Equatable, Sendable {
		public var id: String
		public var saveCache: Bool
		public init(id: String, saveCache: Bool) {
			self.id = id
			self.saveCache = saveCache
		}
	}

	public let capacity: Int
	public private(set) var socketPath: String = ""
	public private(set) var tcpPort: Int?
	public let token: String?
	/// Local TCP port that `connect` pipes to (e.g. `EchoServer.port`).
	public var sshdPort: Int? {
		get { m.withLock { _sshdPort } }
		set { m.withLock { _sshdPort = newValue } }
	}
	/// Test switch: answer 426 `upgrade_required` to clients announcing a lower API version.
	public var requireMinimumClientVersion: Int? {
		get { m.withLock { _minVersion } }
		set { m.withLock { _minVersion = newValue } }
	}

	/// Test switch: `bay.alert` in `/v1/status`.
	public var alert: String? {
		get { m.withLock { _alert } }
		set { m.withLock { _alert = newValue } }
	}

	private let enableTCP: Bool
	private let m = Monitor()
	// All below guarded by `m`.
	private var _sshdPort: Int?
	private var _minVersion: Int?
	private var _alert: String?
	private var _lastLeaseRequest: LeaseRequest?
	private var capsules: [String?]
	private var leaseList: [Lease] = []
	private var queue: [Int] = []
	private var nextTicket = 0
	private var nextLeaseNumber = 1
	private var _releases: [Release] = []
	/// Leases the bay ended on its own (`loseLease`): the real bay answers `410 lease_lost` for them.
	private var ended: Set<String> = []
	private var _renews: [String] = []
	private var stopped = true
	private var listeners: [Listener] = []
	private var open: [Int32: Socket] = [:]
	private var dir: String?
	private var startedAt = nowSeconds()

	public init(capacity: Int = 2, tcp: Bool = false, token: String? = nil) {
		self.capacity = capacity
		self.capsules = Array(repeating: nil, count: capacity)
		self.enableTCP = tcp
		self.token = tcp ? (token ?? "tok-\(UInt32.random(in: 0...UInt32.max))") : nil
	}

	deinit { stop() }

	// MARK: inspection

	public var releases: [Release] { m.withLock { _releases } }
	public var leases: [Lease] { m.withLock { leaseList } }
	/// Lease ids of every successful renew call, in order.
	public var renews: [String] { m.withLock { _renews } }
	/// The body of the most recent POST /v1/leases (for tests of what clients send).
	public var lastLeaseRequest: LeaseRequest? { m.withLock { _lastLeaseRequest } }

	/// Test switch: ends a lease the way the bay does on its own (idle timeout, a bay restart): it
	/// leaves the list, its capsule is free, and GET, renew and connect answer `410 lease_lost`.
	public func loseLease(_ id: String) {
		m.withLock {
			guard let i = leaseList.firstIndex(where: { $0.id == id }) else { return }
			capsules[leaseList.remove(at: i).capsule] = nil
			ended.insert(id)
			m.broadcast()
		}
	}

	// MARK: lifecycle

	public func start() throws {
		var template = Array("/tmp/cryo-test-XXXXXX".utf8CString)
		guard mkdtemp(&template) != nil else { throw SocketError("mkdtemp", errno: errno) }
		let d = String(decoding: template.dropLast().map { UInt8(bitPattern: $0) }, as: UTF8.self)
		let unix = try Listener.unix(path: d + "/bay.sock")
		var all = [unix]
		if enableTCP { all.append(try Listener.tcp(host: "127.0.0.1", port: 0)) }
		m.withLock {
			dir = d
			startedAt = nowSeconds()
			socketPath = d + "/bay.sock"
			tcpPort = all.count > 1 ? all[1].port : nil
			stopped = false
			listeners = all
		}
		for (i, l) in all.enumerated() {
			let isTCP = i == 1
			spawnThread { [self] in
				while !isStopped {
					guard let c = try? l.accept(timeoutMs: 50) else { continue }
					spawnThread { [self] in serve(c, viaTCP: isTCP) }
				}
				l.close()
			}
		}
	}

	public func stop() {
		let (conns, d): ([Socket], String?) = m.withLock {
			if stopped { return ([], nil) }
			stopped = true
			m.broadcast()
			let d = dir
			dir = nil
			return (Array(open.values), d)
		}
		for c in conns { c.shutdownBoth() }
		if let d {
			// Give accept loops a moment to close the listeners (they unlink the socket).
			usleep(120_000)
			unlink(d + "/bay.sock")
			rmdir(d)
		}
	}

	private var isStopped: Bool { m.withLock { stopped } }

	// MARK: serving

	private func serve(_ c: Socket, viaTCP: Bool) {
		let key = c.fd
		let proceed: Bool = m.withLock {
			if stopped { return false }
			open[key] = c
			return true
		}
		guard proceed else {
			c.close()
			return
		}
		defer {
			m.withLock { _ = open.removeValue(forKey: key) }
			c.close()
		}
		c.setTimeouts(receive: 30)
		while true {
			let req: HTTPRequest?
			do {
				req = try HTTPWire.readRequest(from: c)
			} catch let e as HTTPError {
				try? c.writeAll(error(400, APIError.badRequest, "\(e)").serialized())
				return
			} catch {
				return
			}
			guard let req else { return }
			if handleUpgradeIfAny(req, c, viaTCP: viaTCP) != nil { return }
			let resp = route(req, viaTCP: viaTCP)
			do { try c.writeAll(resp.serialized()) } catch { return }
			if req.headers["Connection"]?.lowercased() == "close" { return }
		}
	}

	/// Returns nil when the request is not a connect upgrade, true if it was handled (stream over).
	private func handleUpgradeIfAny(_ req: HTTPRequest, _ c: Socket, viaTCP: Bool) -> Bool? {
		let parts = pathParts(req.path)
		guard req.method == "POST", parts.count == 4, parts[0] == "v1", parts[1] == "leases", parts[3] == "connect" else { return nil }
		if let denied = precheck(req, viaTCP: viaTCP) {
			try? c.writeAll(denied.serialized())
			return true
		}
		let id = parts[2]
		let (exists, port) = m.withLock { (leaseList.contains { $0.id == id }, _sshdPort) }
		guard exists else {
			try? c.writeAll(missing(id).serialized())
			return true
		}
		guard let port, let up = try? Socket.connectTCP(host: "127.0.0.1", port: port) else {
			try? c.writeAll(error(503, APIError.capsuleUnreachable, "capsule sshd is not reachable").serialized())
			return true
		}
		var h = HTTPHeaders()
		h["Connection"] = "Upgrade"
		h["Upgrade"] = "cryo-ssh"
		h[apiVersionHeader] = String(apiVersion)
		guard (try? c.writeAll(HTTPResponse(status: 101, headers: h).serialized())) != nil else {
			up.close()
			return true
		}
		c.setTimeouts(receive: 0)
		// client -> sshd on a helper thread, sshd -> client here.
		let done = Monitor()
		let flag = Flag()
		spawnThread {
			while let data = try? c.read(), !data.isEmpty {
				if (try? up.writeAll(data)) == nil { break }
			}
			up.shutdownWrite()
			done.withLock {
				flag.set()
				done.broadcast()
			}
		}
		while let data = try? up.read(), !data.isEmpty {
			if (try? c.writeAll(data)) == nil { break }
		}
		c.shutdownBoth()
		done.lock()
		while !flag.value { done.wait() }
		done.unlock()
		up.close()
		return true
	}

	private final class Flag: @unchecked Sendable {
		private(set) var value = false
		func set() { value = true }
	}

	private func precheck(_ req: HTTPRequest, viaTCP: Bool) -> HTTPResponse? {
		if viaTCP {
			guard let token, req.headers["Authorization"] == "Bearer \(token)" else {
				return error(401, APIError.unauthorized, "missing or wrong bearer token")
			}
		}
		if let min = m.withLock({ _minVersion }) {
			let v = req.headers[apiVersionHeader].flatMap { Int($0) } ?? 0
			if v < min { return error(426, APIError.upgradeRequired, "client API version \(v) is older than \(min)") }
		}
		return nil
	}

	// MARK: routing

	private func json<T: Encodable>(_ status: Int, _ value: T) -> HTTPResponse {
		var h = HTTPHeaders()
		h["Content-Type"] = "application/json"
		h[apiVersionHeader] = String(apiVersion)
		let body = (try? CryoJSON.encoder().encode(value)) ?? Data()
		return HTTPResponse(status: status, headers: h, body: Array(body))
	}

	private func error(_ status: Int, _ code: String, _ message: String) -> HTTPResponse {
		json(status, APIError(code: code, message: message))
	}

	/// Routes like the real bay (CryoBay/Server.swift): a known path with the wrong method is
	/// `405 bad_request` with `Allow`, an unknown path `404 not_found`.
	private func route(_ req: HTTPRequest, viaTCP: Bool) -> HTTPResponse {
		if let denied = precheck(req, viaTCP: viaTCP) { return denied }
		let parts = pathParts(req.path)
		guard parts.first == "v1", parts.count >= 2 else { return error(404, APIError.notFound, "no such path") }
		let method = req.method
		switch (parts.count, parts[1]) {
		case (2, "leases"):
			switch method {
			case "POST": return createLease(req)
			case "GET": return json(200, leases)
			default: return wrongMethod("GET, POST")
			}
		case (3, "leases"):
			let id = parts[2]
			switch method {
			case "GET":
				guard let l = leases.first(where: { $0.id == id }) else { return missing(id) }
				return json(200, l)
			case "DELETE": return releaseLease(id, saveCache: req.query["save_cache"] == "true")
			default: return wrongMethod("GET, DELETE")
			}
		case (4, "leases") where parts[3] == "renew":
			guard method == "POST" else { return wrongMethod("POST") }
			let id = parts[2]
			guard
				let by = m.withLock({ () -> Date? in
					guard let i = leaseList.firstIndex(where: { $0.id == id }) else { return nil }
					let by = Date(timeIntervalSince1970: (nowSeconds() + Double(leaseList[i].idleS ?? 3600)).rounded(.down))
					leaseList[i].renewBy = by
					_renews.append(id)
					return by
				})
			else { return missing(id) }
			return json(200, RenewResponse(renewBy: by))
		case (4, "leases") where parts[3] == "connect":
			return wrongMethod("POST")
		case (2, "status"):
			guard method == "GET" else { return wrongMethod("GET") }
			return json(200, status())
		case (2, "doctor"):
			guard method == "GET" else { return wrongMethod("GET") }
			return json(
				200,
				[
					DoctorCheck(check: "host unlocked", ok: true),
					DoctorCheck(check: "pf anchor loaded", ok: true),
				])
		default:
			return error(404, APIError.notFound, "no such endpoint \(method) \(req.path)")
		}
	}

	private func wrongMethod(_ allowed: String) -> HTTPResponse {
		var r = error(405, APIError.badRequest, "method not allowed (use \(allowed))")
		r.headers["Allow"] = allowed
		return r
	}

	private func notFound(_ id: String) -> HTTPResponse { error(404, APIError.notFound, "no lease \(id)") }

	/// A lease that is not there: `410 lease_lost` if the bay ended it, else `404 not_found`.
	private func missing(_ id: String) -> HTTPResponse {
		if m.withLock({ ended.contains(id) }) { return error(410, APIError.leaseLost, "lease \(id) lost: idle timeout") }
		return notFound(id)
	}

	private func status() -> Status {
		m.withLock {
			Status(
				bay: .init(version: "fake", image: "fake-image", doctor: Status.doctorOK, alert: _alert),
				capsules: capsules.enumerated().map { .init(n: $0, state: $1 == nil ? "thawed" : "leased", lease: $1) },
				queue: queue.count,
				// Fixed host readings; the lease counter is real so tests see it move.
				health: .init(
					uptimeS: Int(nowSeconds() - startedAt), hostUptimeS: 3 * 86400, diskFreeBytes: 120_000_000_000,
					thermal: "nominal", leasesServed: nextLeaseNumber - 1, refills: _releases.count,
					lastLeaseMS: nextLeaseNumber > 1 ? 812 : nil))
		}
	}

	private func createLease(_ req: HTTPRequest) -> HTTPResponse {
		var lr = LeaseRequest()
		if !req.body.isEmpty {
			guard let parsed = try? CryoJSON.decoder().decode(LeaseRequest.self, from: Data(req.body)) else {
				return error(400, APIError.badRequest, "body is not a lease request")
			}
			lr = parsed
		}
		m.withLock { _lastLeaseRequest = lr }
		let wait = lr.waitS ?? 600
		let deadline = nowSeconds() + Double(wait)
		m.lock()
		defer { m.unlock() }
		let ticket = nextTicket
		nextTicket += 1
		queue.append(ticket)
		func leave() {
			queue.removeAll { $0 == ticket }
			m.broadcast()
		}
		while true {
			if stopped {
				leave()
				return error(503, APIError.noCapacity, "bay is stopping")
			}
			if queue.first == ticket, let n = capsules.firstIndex(where: { $0 == nil }) {
				let id = "L\(nextLeaseNumber)"
				nextLeaseNumber += 1
				capsules[n] = id
				let now = Date(timeIntervalSince1970: nowSeconds().rounded(.down))
				// Like the real bay's LeasePolicy: default 3600, at least 1 s, at most a day.
				let idle = min(max(lr.idleS ?? 3600, 1), 86400)
				let lease = Lease(
					id: id, name: lr.name, capsule: n, state: "leased", createdAt: now,
					renewBy: now.addingTimeInterval(Double(idle)), expiresAt: now.addingTimeInterval(86400), cache: lr.cache,
					idleS: idle,
					ssh: SSHInfo(
						user: "cryo", host: "cryo-\(id)",
						key: "-----BEGIN OPENSSH PRIVATE KEY-----\nfake-key-\(id)\n-----END OPENSSH PRIVATE KEY-----\n",
						config: "Host cryo-\(id)\n  User cryo\n  ProxyCommand cryo ssh \(id)\n  IdentityFile ~/.cryo/keys/\(id)\n"
							+ "  HostKeyAlias cryo-\(id)\n  UserKnownHostsFile ~/.cryo/known_hosts/\(id)\n  GlobalKnownHostsFile /dev/null\n"
							+ "  StrictHostKeyChecking yes",
						hostKey: "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIFakeHostKey\(id)"))
				leaseList.append(lease)
				leave()
				return json(201, lease)
			}
			if wait <= 0 || !m.wait(until: deadline) {
				leave()
				return error(503, APIError.noCapacity, "no free capsule")
			}
		}
	}

	private func releaseLease(_ id: String, saveCache: Bool) -> HTTPResponse {
		m.withLock {
			guard let i = leaseList.firstIndex(where: { $0.id == id }) else { return notFound(id) }
			let l = leaseList.remove(at: i)
			capsules[l.capsule] = nil
			_releases.append(Release(id: id, saveCache: saveCache))
			m.broadcast()
			var h = HTTPHeaders()
			h[apiVersionHeader] = String(apiVersion)
			return HTTPResponse(status: 204, headers: h)
		}
	}
}

/// Path segments, percent-decoded like the real bay does (clients encode lease ids).
private func pathParts(_ path: String) -> [String] {
	path.split(separator: "/").map { percentDecoded(String($0)) }
}

private func percentDecoded(_ s: String) -> String {
	guard s.contains("%") else { return s }
	let bytes = Array(s.utf8)
	var out: [UInt8] = []
	var i = 0
	func hex(_ b: UInt8) -> UInt8? {
		switch b {
		case 0x30...0x39: return b - 0x30
		case 0x41...0x46: return b - 0x41 + 10
		case 0x61...0x66: return b - 0x61 + 10
		default: return nil
		}
	}
	while i < bytes.count {
		if bytes[i] == 0x25, i + 2 < bytes.count, let h = hex(bytes[i + 1]), let l = hex(bytes[i + 2]) {
			out.append(h << 4 | l)
			i += 3
		} else {
			if bytes[i] == 0x25 { return s }  // malformed: keep it as sent, like removingPercentEncoding's fallback
			out.append(bytes[i])
			i += 1
		}
	}
	return String(validating: out, as: UTF8.self) ?? s
}

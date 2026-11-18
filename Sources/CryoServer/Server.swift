import CryoAPI
import CryoHTTP
import Foundation

public struct ServerError: Error, CustomStringConvertible {
	public let description: String
	public init(_ description: String) { self.description = description }
}

/// The bay's HTTP API (docs/spec/api.md) on a unix socket and, optionally, a token-protected TCP
/// port. Thread per connection with blocking sockets; each request bridges into the async
/// `BayService` and waits, so a slow `createLease` never blocks `status` on another connection.
public final class BayServer: @unchecked Sendable {
	private let service: any BayService
	private let log: ServerLog
	public let socketPath: String
	private let m = Monitor()
	// Guarded by `m`.
	private var stopped = true
	private var listeners: [Listener] = []
	private var acceptors = 0
	private var open: [Int32: Socket] = [:]
	private var _token: String?
	private var _tcpPort: Int?
	private var _minVersion: Int?

	/// Serves `service` on the unix socket `socketPath` (plus TCP once `start` is given a listener).
	public init(service: any BayService, socketPath: String, log: ServerLog = .server) {
		self.service = service
		self.socketPath = socketPath
		self.log = log
	}

	deinit { stop() }

	/// The bound TCP port (useful with port 0), nil when there is no TCP listener.
	public var tcpPort: Int? { m.withLock { _tcpPort } }
	/// Same switch as FakeBay's: answer 426 `upgrade_required` to clients announcing a lower API
	/// version. v1 accepts every v1 client, so nil by default.
	public var minimumClientVersion: Int? {
		get { m.withLock { _minVersion } }
		set { m.withLock { _minVersion = newValue } }
	}

	/// Parses `--listen` values: `:7477`, `7477` (all interfaces) or `host:port`.
	public static func parseListen(_ s: String) -> (host: String, port: Int)? {
		let part = s.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
		let host: String
		let port: String
		if part.count == 1 { (host, port) = ("", String(part[0])) } else { (host, port) = (String(part[0]), String(part[1])) }
		guard let p = Int(port), (0...65535).contains(p) else { return nil }
		return (host.isEmpty ? "0.0.0.0" : host, p)
	}

	// MARK: lifecycle

	public func start(listen: (host: String, port: Int)?, token: String?) throws {
		if m.withLock({ !stopped }) { throw ServerError("server already started") }
		if listen != nil, token?.isEmpty ?? true { throw ServerError("a network listener needs a bearer token") }
		let path = socketPath

		// A leftover socket file is stale unless something still answers on it.
		if pathExists(path) {
			if let probe = try? Socket.connectUnix(path: path) {
				probe.close()
				throw ServerError("another bay is running (\(path) answers)")
			}
			unlink(path)
		}
		// Not umask: it is process-wide, so briefly changing it would give files other threads
		// create meanwhile the wrong mode. Listener.unix chmods to 0600 right after bind; the
		// window is only as wide as ~/.cryo itself, which the bay keeps owner-only.
		let unix = try Listener.unix(path: path)
		_ = chmod(path, 0o600)
		var all = [unix]
		if let listen {
			do { all.append(try Listener.tcp(host: listen.host, port: listen.port)) } catch {
				unix.close()
				throw error
			}
		}
		m.withLock {
			stopped = false
			listeners = all
			_token = token
			_tcpPort = listen == nil ? nil : all[1].port
			acceptors = all.count
		}
		for (i, l) in all.enumerated() {
			let viaTCP = i == 1
			spawnThread { [self] in
				var failures = 0
				// 50 ms: how long `stop()` waits for this loop to notice. Polling that often costs nothing.
				while !isStopped {
					let accepted: Socket?
					do {
						accepted = try l.accept(timeoutMs: 50)
					} catch {
						// A lasting error (EMFILE: out of file descriptors) leaves the listener readable,
						// so retrying at once would spin a core. Back off up to 0.5 s; log once per streak.
						if failures == 0 { log.error("accept failed, backing off: \(String(describing: error))") }
						failures += 1
						usleep(UInt32(min(10_000 << min(failures, 6), 500_000)))
						continue
					}
					if failures > 0 {
						log.info("accept works again after \(failures) failures")
						failures = 0
					}
					guard let c = accepted else { continue }
					spawnThread { [self] in serve(c, viaTCP: viaTCP) }
				}
				l.close()
				m.withLock {
					acceptors -= 1
					m.broadcast()
				}
			}
		}
		log.info("api listening on \(path)\(listen.map { " and \($0.host):\(self.tcpPort ?? $0.port)" } ?? "")")
	}

	public func stop() {
		let conns: [Socket] = m.withLock {
			if stopped { return [] }
			stopped = true
			m.broadcast()
			return Array(open.values)
		}
		for c in conns { c.shutdownBoth() }
		// The accept loops close the listeners (which unlinks the socket); wait so a restart can rebind.
		m.lock()
		let deadline = nowSeconds() + 2
		while acceptors > 0, m.wait(until: deadline) {}
		m.unlock()
	}

	private var isStopped: Bool { m.withLock { stopped } }

	private func track(_ s: Socket) -> Bool {
		m.withLock {
			if stopped { return false }
			open[s.fd] = s
			return true
		}
	}

	private func untrack(_ s: Socket) { m.withLock { _ = open.removeValue(forKey: s.fd) } }

	// MARK: bridging

	/// Runs async work from this connection thread and waits for it. With `watching`, a peer that
	/// hangs up while we wait cancels the work: a queued lease request must not take a capsule for
	/// a client that is gone.
	private func blocking<T: Sendable>(watching sock: Socket? = nil, _ body: @escaping @Sendable () async throws -> T) throws -> T {
		let box = ResultBox<T>()
		let task = Task.detached {
			let r: Result<T, Error>
			do { r = .success(try await body()) } catch { r = .failure(error) }
			box.m.withLock {
				box.result = r
				box.m.broadcast()
			}
		}
		box.m.lock()
		var cancelled = false
		while box.result == nil {
			if sock == nil {
				box.m.wait()
			} else {
				box.m.wait(until: nowSeconds() + 0.25)
				if box.result == nil, !cancelled, let sock, peerGone(sock) {
					cancelled = true
					task.cancel()
				}
			}
		}
		let r = box.result!
		box.m.unlock()
		return try r.get()
	}

	private final class ResultBox<T: Sendable>: @unchecked Sendable {
		let m = Monitor()
		var result: Result<T, Error>?
	}

	private func peerGone(_ s: Socket) -> Bool {
		var p = pollfd(fd: s.fd, events: Int16(POLLIN), revents: 0)
		guard poll(&p, 1, 0) > 0 else { return false }
		var b: UInt8 = 0
		return recv(s.fd, &b, 1, Int32(MSG_PEEK | MSG_DONTWAIT)) == 0
	}

	// MARK: serving

	private func serve(_ c: Socket, viaTCP: Bool) {
		guard track(c) else {
			c.close()
			return
		}
		defer {
			untrack(c)
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
			let parts = req.path.split(separator: "/").map { String($0).removingPercentEncoding ?? String($0) }
			let resp: HTTPResponse
			if let denied = precheck(req, viaTCP: viaTCP) {
				resp = denied
			} else if req.method == "POST", parts.count == 4, parts[0] == "v1", parts[1] == "leases", parts[3] == "connect" {
				// After a 101 the connection is a raw stream, so it never returns to the request loop.
				if let early = connect(req, id: parts[2], c) { try? c.writeAll(early.serialized()) }
				return
			} else {
				resp = route(req, parts: parts, c, viaTCP: viaTCP)
			}
			log.debug("\(req.method) \(req.path) -> \(resp.status)")
			do { try c.writeAll(resp.serialized()) } catch { return }
			if req.headers["Connection"]?.lowercased() == "close" { return }
		}
	}

	private func precheck(_ req: HTTPRequest, viaTCP: Bool) -> HTTPResponse? {
		if viaTCP {
			let expected = m.withLock { _token } ?? ""
			let given = req.headers["Authorization"].flatMap { $0.hasPrefix("Bearer ") ? String($0.dropFirst(7)) : nil } ?? ""
			guard !expected.isEmpty, constantTimeEqual(given, expected) else {
				return error(401, APIError.unauthorized, "missing or wrong bearer token")
			}
		}
		if let min = minimumClientVersion {
			let v = req.headers[apiVersionHeader].flatMap { Int($0) } ?? 0
			if v < min { return error(426, APIError.upgradeRequired, "client API version \(v) is older than \(min)") }
		}
		return nil
	}

	// MARK: routing

	private func route(_ req: HTTPRequest, parts: [String], _ c: Socket, viaTCP: Bool) -> HTTPResponse {
		guard parts.first == "v1", parts.count >= 2 else { return error(404, APIError.notFound, "no such path") }
		let svc = service
		let method = req.method
		do {
			switch (parts.count, parts[1]) {
			case (2, "leases"):
				switch method {
				case "POST":
					var lr = LeaseRequest()
					if !req.body.isEmpty {
						guard let parsed = try? CryoJSON.decoder().decode(LeaseRequest.self, from: Data(req.body)) else {
							return error(400, APIError.badRequest, "body is not a lease request")
						}
						lr = parsed
					}
					let request = lr
					return json(201, try blocking(watching: c) { try await svc.createLease(request, viaNetwork: viaTCP) })
				case "GET": return json(200, try blocking { await svc.leases() })
				default: return wrongMethod("GET, POST")
				}
			case (3, "leases"):
				let id = parts[2]
				switch method {
				case "GET": return json(200, try blocking { try await svc.lease(id) })
				case "DELETE":
					let save = req.query["save_cache"] == "true"
					try blocking { try await svc.release(id, saveCache: save) }
					return HTTPResponse(status: 204, headers: baseHeaders())
				default: return wrongMethod("GET, DELETE")
				}
			case (4, "leases") where parts[3] == "renew":
				guard method == "POST" else { return wrongMethod("POST") }
				let id = parts[2]
				return json(200, try blocking { try await svc.renew(id) })
			case (4, "leases") where parts[3] == "connect":
				return wrongMethod("POST")
			case (2, "status"):
				guard method == "GET" else { return wrongMethod("GET") }
				return json(200, try blocking { await svc.status() })
			case (2, "doctor"):
				guard method == "GET" else { return wrongMethod("GET") }
				return json(200, try blocking { await svc.doctor() })
			case (2, "drain"), (2, "undrain"), (2, "image"):
				guard method == "POST" else { return wrongMethod("POST") }
				return admin(viaTCP: viaTCP)
			case (4, "capsules") where parts[3] == "refreeze" && Int(parts[2]) != nil:
				guard method == "POST" else { return wrongMethod("POST") }
				return admin(viaTCP: viaTCP)
			default:
				return error(404, APIError.notFound, "no such endpoint \(method) \(req.path)")
			}
		} catch {
			return errorResponse(error)
		}
	}

	/// Admin endpoints are local-only; the engine does not implement them yet.
	private func admin(viaTCP: Bool) -> HTTPResponse {
		if viaTCP { return error(403, APIError.unauthorized, "admin endpoints are available on the unix socket only") }
		return error(501, "not_implemented", "not implemented yet")
	}

	private func wrongMethod(_ allowed: String) -> HTTPResponse {
		var r = error(405, APIError.badRequest, "method not allowed (use \(allowed))")
		r.headers["Allow"] = allowed
		return r
	}

	// MARK: connect

	/// Returns a response to send when the request is refused; nil when the stream was handled.
	private func connect(_ req: HTTPRequest, id: String, _ c: Socket) -> HTTPResponse? {
		let wantsUpgrade = (req.headers["Connection"] ?? "").lowercased().split(separator: ",").contains {
			$0.trimmingCharacters(in: .whitespaces) == "upgrade"
		}
		guard wantsUpgrade, req.headers["Upgrade"]?.lowercased() == "cryo-ssh" else {
			return error(400, APIError.badRequest, "connect needs `Connection: Upgrade` and `Upgrade: cryo-ssh`")
		}
		let svc = service
		let route: ConnectRoute
		do { route = try blocking { try await svc.connectRoute(id) } } catch { return errorResponse(error) }
		let up: Socket
		switch route {
		case .tcp(let host, let port):
			guard let s = try? Socket.connectTCP(host: host, port: port, timeout: 3) else {
				log.error("lease \(id): capsule sshd \(host):\(port) is not reachable")
				return error(503, APIError.capsuleUnreachable, "capsule sshd for lease \(id) is not reachable")
			}
			up = s
		case .upstream(let open):
			do { up = try open() } catch {
				return errorResponse(error)
			}
		}
		var h = HTTPHeaders()
		h["Connection"] = "Upgrade"
		h["Upgrade"] = "cryo-ssh"
		h[apiVersionHeader] = String(apiVersion)
		guard (try? c.writeAll(HTTPResponse(status: 101, headers: h).serialized())) != nil else {
			up.close()
			return nil
		}
		c.setTimeouts(receive: 0)
		guard track(up) else {
			up.close()
			return nil
		}
		try? blocking { await svc.connectionOpened(id) }
		let watch = StreamWatch()
		spawnThread { [self] in endWithLease(id, watch, c, up) }
		pipe(c, up)
		watch.m.withLock {
			watch.finished = true
			watch.m.broadcast()
		}
		untrack(up)
		up.close()
		// Exactly once: both directions are finished at this point.
		try? blocking { await svc.connectionClosed(id) }
		return nil
	}

	/// Copies both ways. EOF from one side is passed on as a half-close and the other direction
	/// keeps flowing; an error tears down both. Returns when both directions are done.
	private func pipe(_ c: Socket, _ up: Socket) {
		let done = Monitor()
		let flag = DoneFlag()
		spawnThread {
			while let data = try? c.read(), !data.isEmpty {
				if (try? up.writeAll(data)) == nil {
					c.shutdownBoth()
					up.shutdownBoth()
					break
				}
			}
			up.shutdownWrite()
			done.withLock {
				flag.value = true
				done.broadcast()
			}
		}
		while true {
			guard let data = try? up.read() else {
				c.shutdownBoth()
				up.shutdownBoth()
				break
			}
			if data.isEmpty {
				c.shutdownWrite()
				break
			}
			if (try? c.writeAll(data)) == nil {
				c.shutdownBoth()
				up.shutdownBoth()
				break
			}
		}
		done.lock()
		while !flag.value { done.wait() }
		done.unlock()
	}

	private final class DoneFlag: @unchecked Sendable { var value = false }

	private final class StreamWatch: @unchecked Sendable {
		let m = Monitor()
		var finished = false
	}

	/// How often an open stream checks that its lease is still there (seconds).
	var leaseCheckInterval = 2.0

	/// Ends the stream when its lease ends (release, idle or max length). A stopped VM sends no FIN,
	/// so without this `up.read()` waits forever and the client's ssh hangs. Shuts down while
	/// holding `watch.m`: the sockets are closed only after `finished`, so the fds are still theirs.
	private func endWithLease(_ id: String, _ watch: StreamWatch, _ c: Socket, _ up: Socket) {
		let svc = service
		watch.m.lock()
		defer { watch.m.unlock() }
		while !watch.finished {
			watch.m.wait(until: nowSeconds() + leaseCheckInterval)
			if watch.finished { return }
			watch.m.unlock()
			let alive = (try? blocking { try await svc.lease(id) }) != nil
			watch.m.lock()
			if !alive, !watch.finished {
				log.info("lease \(id) ended: closing its connect stream")
				c.shutdownBoth()
				up.shutdownBoth()
				return
			}
		}
	}

	// MARK: responses

	private func baseHeaders() -> HTTPHeaders {
		var h = HTTPHeaders()
		h[apiVersionHeader] = String(apiVersion)
		return h
	}

	private func json<T: Encodable>(_ status: Int, _ value: T) -> HTTPResponse {
		var h = baseHeaders()
		h["Content-Type"] = "application/json"
		let body = (try? CryoJSON.encoder().encode(value)) ?? Data()
		return HTTPResponse(status: status, reason: Self.reason(status), headers: h, body: Array(body))
	}

	private func error(_ status: Int, _ code: String, _ message: String) -> HTTPResponse {
		json(status, APIError(code: code, message: message))
	}

	private func errorResponse(_ e: Error) -> HTTPResponse {
		if let s = e as? ServiceError { return error(s.status, s.code, s.message) }
		log.error("internal error: \(String(describing: e))")
		return error(500, "internal", "\(e)")
	}

	private static func reason(_ status: Int) -> String {
		switch status {
		case 403: return "Forbidden"
		case 405: return "Method Not Allowed"
		case 410: return "Gone"
		case 501: return "Not Implemented"
		default: return HTTPResponse.defaultReason(status)
		}
	}
}

/// Compares without stopping at the first difference, so timing does not reveal the token.
func constantTimeEqual(_ a: String, _ b: String) -> Bool {
	let x = Array(a.utf8)
	let y = Array(b.utf8)
	var diff = x.count ^ y.count
	for i in 0..<max(x.count, y.count) {
		diff |= Int(i < x.count ? x[i] : 0) ^ Int(i < y.count ? y[i] : 0)
	}
	return diff == 0
}

private func pathExists(_ path: String) -> Bool {
	var st = stat()
	return lstat(path, &st) == 0
}

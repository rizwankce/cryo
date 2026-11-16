import CryoHTTP
import Testing

#if canImport(FoundationEssentials)
	import FoundationEssentials
#else
	import Foundation
#endif

/// A connected TCP pair on loopback: `client` writes what the test sends, `server` is what is parsed.
private struct Pair {
	let client: Socket
	let server: Socket

	init() throws {
		let l = try Listener.tcp(host: "127.0.0.1", port: 0)
		defer { l.close() }
		client = try Socket.connectTCP(host: "127.0.0.1", port: l.port!)
		guard let s = try l.accept(timeoutMs: 2000) else { throw SocketError("no connection accepted") }
		server = s
		server.setTimeouts(receive: 5)
	}

	func send(_ s: String) throws { try client.writeAll(Array(s.utf8)) }
}

private func request(_ method: String, _ target: String, body: String = "") -> String {
	String(decoding: HTTPRequest(method: method, target: target, body: Array(body.utf8)).serialized(), as: UTF8.self)
}

@Suite struct ReadRequestTests {
	@Test func twoRequestsOnOneConnection() throws {
		let p = try Pair()
		// The first is longer than the second: the old stale scan index sliced past the new buffer.
		try p.send(request("POST", "/v1/leases/some-long-lease-id/renew", body: "{\"x\": 1}"))
		let a = try #require(try HTTPWire.readRequest(from: p.server))
		#expect(a.method == "POST" && a.target == "/v1/leases/some-long-lease-id/renew")
		#expect(a.body == Array("{\"x\": 1}".utf8))
		try p.send(request("GET", "/v1/status"))
		let b = try #require(try HTTPWire.readRequest(from: p.server))
		#expect(b.method == "GET" && b.target == "/v1/status")
		#expect(b.body.isEmpty)
	}

	@Test func threeRequestsOfDifferentLengths() throws {
		let p = try Pair()
		let sent: [(String, String, String)] = [
			("GET", "/v1/status", ""),
			("POST", "/v1/leases", String(repeating: "x", count: 3000)),
			("DELETE", "/v1/leases/L1?save_cache=true", ""),
		]
		for (method, target, body) in sent {
			try p.send(request(method, target, body: body))
			let r = try #require(try HTTPWire.readRequest(from: p.server))
			#expect(r.method == method && r.target == target)
			#expect(r.body == Array(body.utf8))
		}
		p.client.close()
		#expect(try HTTPWire.readRequest(from: p.server) == nil)
	}

	@Test func pipelinedRequestsInOneWrite() throws {
		let p = try Pair()
		try p.send(request("GET", "/a") + request("POST", "/bb", body: "hello") + request("GET", "/ccc"))
		for target in ["/a", "/bb", "/ccc"] {
			let r = try #require(try HTTPWire.readRequest(from: p.server))
			#expect(r.target == target)
		}
	}

	@Test func headSplitAcrossManyWrites() throws {
		let p = try Pair()
		let whole = Array(request("POST", "/v1/leases", body: "{\"name\":\"job\"}").utf8)
		// One byte at a time on a thread, with pauses so they arrive as separate segments.
		spawnThread {
			for b in whole {
				try? p.client.writeAll([b])
				usleep(500)
			}
		}
		let r = try #require(try HTTPWire.readRequest(from: p.server))
		#expect(r.method == "POST" && r.target == "/v1/leases")
		#expect(r.headers["Content-Length"] == "14")
		#expect(r.body == Array("{\"name\":\"job\"}".utf8))
	}

	@Test func lineLongerThanTheMaximum() throws {
		let p = try Pair()
		try p.send("GET /" + String(repeating: "a", count: 70 * 1024) + " HTTP/1.1\r\n\r\n")
		#expect(throws: SocketError.self) { _ = try HTTPWire.readRequest(from: p.server) }
	}

	@Test func lineAtTheMaximumIsFineAndOneMoreIsNot() throws {
		let p = try Pair()
		try p.send(String(repeating: "a", count: 16) + "\r\n" + String(repeating: "b", count: 17) + "\n")
		#expect(try p.server.readLine(maxLength: 16) == String(repeating: "a", count: 16))
		#expect(throws: SocketError.self) { _ = try p.server.readLine(maxLength: 16) }
	}

	@Test func eofMidLine() throws {
		let p = try Pair()
		try p.send("GET /v1/sta")
		p.client.shutdownWrite()
		do {
			_ = try HTTPWire.readRequest(from: p.server)
			Issue.record("expected an error")
		} catch let e as SocketError {
			#expect(e.kind == .eof)
		}
	}

	@Test func eofBeforeAnythingIsNil() throws {
		let p = try Pair()
		p.client.shutdownWrite()
		#expect(try HTTPWire.readRequest(from: p.server) == nil)
	}

	@Test func duplicateContentLengthIsRefused() throws {
		let p = try Pair()
		try p.send("POST /v1/leases HTTP/1.1\r\nContent-Length: 2\r\nContent-Length: 2\r\n\r\n{}")
		#expect(throws: HTTPError.self) { _ = try HTTPWire.readRequest(from: p.server) }
	}

	@Test func conflictingContentLengthIsRefused() throws {
		let p = try Pair()
		try p.send("POST /v1/leases HTTP/1.1\r\nContent-Length: 2\r\ncontent-length: 7\r\n\r\n{}")
		#expect(throws: HTTPError.self) { _ = try HTTPWire.readRequest(from: p.server) }
	}

	@Test func badContentLengthIsRefused() throws {
		let p = try Pair()
		try p.send("POST /v1/leases HTTP/1.1\r\nContent-Length: -1\r\n\r\n")
		#expect(throws: HTTPError.self) { _ = try HTTPWire.readRequest(from: p.server) }
	}
}

@Suite struct ConnectTests {
	/// A host that is down never answers the SYN: the connect must give up at the timeout, not after
	/// the kernel's ~75 s. Two ways to get no answer, since each works on only some systems: a
	/// listener with a full queue (Linux drops the SYN; macOS still completes the handshake) and
	/// addresses nothing answers on (macOS drops 127.0.0.2 without an alias; the TEST-NET and private
	/// ones go unanswered where there is a route).
	@Test func connectTimesOutWhenNobodyAnswers() throws {
		var timeouts = 0
		func attempt(_ host: String, _ port: Int) -> Socket? {
			let t0 = nowSeconds()
			do {
				return try Socket.connectTCP(host: host, port: port, timeout: 0.3)
			} catch let e as SocketError {
				let took = nowSeconds() - t0
				#expect(took < 2, "\(host): \(e)")
				if e.kind == .timeout {
					timeouts += 1
					#expect(took >= 0.25, "\(host)")
				}
			} catch {
				Issue.record("\(host): \(error)")
			}
			return nil
		}
		let l = try Listener.tcp(host: "127.0.0.1", port: 0)
		defer { l.close() }
		_ = listen(l.fd, 0)  // the smallest queue, so a few connects fill it
		var queued: [Socket] = []
		defer { for s in queued { s.close() } }
		for _ in 0..<20 {
			guard let s = attempt("127.0.0.1", l.port!) else { break }
			queued.append(s)
		}
		for host in ["127.0.0.2", "192.0.2.1", "10.255.255.1"] {
			attempt(host, 9)?.close()
		}
		#expect(timeouts > 0)
	}

	@Test func refusedFailsAtOnce() throws {
		let l = try Listener.tcp(host: "127.0.0.1", port: 0)
		let port = l.port!
		l.close()
		let t0 = nowSeconds()
		do {
			_ = try Socket.connectTCP(host: "127.0.0.1", port: port, timeout: 5)
			Issue.record("expected connection refused")
		} catch let e as SocketError {
			#expect(e.kind == .failed)
		}
		#expect(nowSeconds() - t0 < 1)
	}

	@Test func connectedSocketIsBlockingAgain() throws {
		let p = try Pair()
		// A non-blocking socket would fail this read at once with EAGAIN instead of waiting.
		spawnThread {
			usleep(100_000)
			try? p.server.writeAll([1, 2, 3])
		}
		p.client.setTimeouts(receive: 5)
		#expect(try p.client.readExactly(3) == [1, 2, 3])
	}
}

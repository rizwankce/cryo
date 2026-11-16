import CryoAPI
import CryoHTTP
import FakeBay
import Testing

@testable import CryoClient

#if canImport(FoundationEssentials)
	import FoundationEssentials
#else
	import Foundation
#endif

private func unixClient(_ bay: FakeBay) -> CryoClient {
	CryoClient(target: CryoTarget(endpoint: .unix(path: bay.socketPath)))
}

private func withBay<T>(capacity: Int = 2, tcp: Bool = false, _ body: (FakeBay) throws -> T) throws -> T {
	let bay = FakeBay(capacity: capacity, tcp: tcp)
	try bay.start()
	defer { bay.stop() }
	return try body(bay)
}

private func apiError(_ body: () throws -> Void) -> (APIError, Int)? {
	do { try body() } catch CryoClientError.api(let e, let status) { return (e, status) } catch {}
	return nil
}

@Suite struct TargetTests {
	@Test func defaultsAndTildeExpansion() throws {
		let t = try CryoTarget(environment: ["HOME": "/home/x"])
		#expect(t.endpoint == .unix(path: "/home/x/.cryo/bay.sock"))
		#expect(t.token == nil)
		#expect(t.display == "unix:///home/x/.cryo/bay.sock")
		let t2 = try CryoTarget(environment: ["CRYO_URL": "unix://~/a.sock", "HOME": "/h", "CRYO_TOKEN": "tk"])
		#expect(t2.endpoint == .unix(path: "/h/a.sock"))
		#expect(t2.token == "tk")
	}

	@Test func schemes() throws {
		#expect(try CryoTarget(url: "unix:///var/run/b.sock").endpoint == .unix(path: "/var/run/b.sock"))
		#expect(try CryoTarget(url: "http://mini.local:7477").endpoint == .tcp(host: "mini.local", port: 7477))
		#expect(try CryoTarget(url: "http://mini.local/").endpoint == .tcp(host: "mini.local", port: 7477))
		#expect(try CryoTarget(url: "http://[::1]:9").endpoint == .tcp(host: "::1", port: 9))
		#expect(throws: CryoClientError.self) { try CryoTarget(url: "unix://relative.sock") }
		#expect(throws: CryoClientError.self) { try CryoTarget(url: "ftp://x") }
		#expect(throws: CryoClientError.self) { try CryoTarget(url: "http://h:notaport") }
	}

	@Test func httpsIsRejectedClearly() {
		do {
			_ = try CryoTarget(url: "https://mini.local:7477")
			Issue.record("expected an error")
		} catch {
			#expect("\(error)".contains("TLS is not supported; use http:// on a trusted network"))
		}
	}

	@Test func missingBayMessageNamesTarget() {
		let c = CryoClient(target: CryoTarget(endpoint: .unix(path: "/tmp/cryo-nonexistent.sock")))
		do {
			_ = try c.status()
			Issue.record("expected an error")
		} catch let CryoClientError.transport(target, _) {
			#expect(target == "unix:///tmp/cryo-nonexistent.sock")
			#expect(
				"\(CryoClientError.transport(target: target, message: "x"))".contains("no bay at unix:///tmp/cryo-nonexistent.sock — is `cryo bay` running?"))
		} catch {
			Issue.record("wrong error \(error)")
		}
	}
}

@Suite struct ClientTests {
	@Test func leaseLifecycleOverUnixSocket() throws {
		try withBay { bay in
			let c = unixClient(bay)
			let l = try c.createLease(LeaseRequest(cache: "app", waitS: 0, name: "fix-login"))
			#expect(l.id == "L1")
			#expect(l.name == "fix-login")
			#expect(l.cache == "app")
			#expect(l.idleS == 3600)
			#expect(l.ssh.host == "cryo-L1")
			#expect(l.ssh.config.hasSuffix("  UserKnownHostsFile ~/.cryo/known_hosts/L1\n  GlobalKnownHostsFile /dev/null\n  StrictHostKeyChecking yes"))
			#expect(l.ssh.hostKey == "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIFakeHostKeyL1")
			#expect(try c.lease("L1") == l)
			#expect(try c.listLeases() == [l])
			let st = try c.status()
			#expect(st.capsules.map(\.state) == ["leased", "thawed"])
			#expect(st.capsules[0].lease == "L1")
			#expect(st.queue == 0)
			#expect(st.bay.doctorOK)
			#expect(try c.doctor().allSatisfy(\.ok))
			try c.release("L1")
			#expect(try c.listLeases().isEmpty)
			#expect(bay.releases == [.init(id: "L1", saveCache: false)])
		}
	}

	@Test func renewMovesDeadline() throws {
		try withBay { bay in
			let c = unixClient(bay)
			let l = try c.createLease(LeaseRequest(waitS: 0))
			let r = try c.renew(l.id)
			// Like the real bay: renew_by moves out by the lease's idle timeout (default 3600).
			#expect(r.renewBy.timeIntervalSinceNow > 3580)
			#expect(r.renewBy.timeIntervalSinceNow <= 3600)
			#expect(try c.lease(l.id).renewBy == r.renewBy)
			let short = try c.createLease(LeaseRequest(waitS: 0, idleS: 90))
			#expect(short.renewBy.timeIntervalSince(short.createdAt) == 90)
			#expect(try c.renew(short.id).renewBy.timeIntervalSinceNow <= 90)
		}
	}

	@Test func wrongMethodIs405LikeTheRealBay() throws {
		try withBay { bay in
			let c = unixClient(bay)
			let (e, status) = try #require(apiError { _ = try c.send("PUT", "/v1/leases") })
			#expect(status == 405 && e.code == APIError.badRequest)
			#expect(apiError { _ = try c.send("POST", "/v1/status") }?.1 == 405)
			#expect(apiError { _ = try c.send("GET", "/v1/nothing") }?.1 == 404)
		}
	}

	@Test func lostLeaseIs410ButReleaseIs404() throws {
		try withBay { bay in
			let c = unixClient(bay)
			let l = try c.createLease(LeaseRequest(waitS: 0))
			bay.loseLease(l.id)
			#expect(bay.leases.isEmpty)
			for call in [{ _ = try c.lease(l.id) }, { _ = try c.renew(l.id) }, { _ = try c.connect(l.id) }] {
				let (e, status) = try #require(apiError(call))
				#expect(e.code == APIError.leaseLost && status == 410)
			}
			#expect(apiError { try c.release(l.id) }?.0.code == APIError.notFound)
			#expect(try c.status().capsules.allSatisfy { $0.lease == nil })
		}
	}

	@Test func encodedIDsAreDecoded() throws {
		try withBay { bay in
			let c = unixClient(bay)
			_ = try c.createLease(LeaseRequest(waitS: 0))
			#expect(try c.send("GET", "/v1/leases/%4C1").status == 200)
			let (e, _) = try #require(apiError { _ = try c.lease("a b/c") })
			#expect(e.message == "no lease a b/c")
		}
	}

	@Test func releaseRecordsSaveCache() throws {
		try withBay { bay in
			let c = unixClient(bay)
			let a = try c.createLease(LeaseRequest(waitS: 0))
			let b = try c.createLease(LeaseRequest(waitS: 0))
			try c.release(a.id, saveCache: true)
			try c.release(b.id)
			#expect(bay.releases == [.init(id: "L1", saveCache: true), .init(id: "L2", saveCache: false)])
		}
	}

	@Test func notFound() throws {
		try withBay { bay in
			let c = unixClient(bay)
			for call in [{ _ = try c.lease("nope") }, { try c.release("nope") }, { _ = try c.renew("nope") }] {
				let (e, status) = try #require(apiError(call))
				#expect(e.code == APIError.notFound)
				#expect(status == 404)
			}
		}
	}

	@Test func noCapacityWithWaitZero() throws {
		try withBay(capacity: 1) { bay in
			let c = unixClient(bay)
			_ = try c.createLease(LeaseRequest(waitS: 0))
			let (e, status) = try #require(apiError { _ = try c.createLease(LeaseRequest(waitS: 0)) })
			#expect(e.code == APIError.noCapacity)
			#expect(status == 503)
		}
	}

	@Test func queuedLeaseIsServedAfterRelease() throws {
		try withBay(capacity: 1) { bay in
			let c = unixClient(bay)
			let first = try c.createLease(LeaseRequest(waitS: 0))
			let result = ResultBox<Lease>()
			spawnThread {
				result.set(Result { try c.createLease(LeaseRequest(waitS: 2)) })
			}
			// Wait until the second request is queued.
			var queued = false
			for _ in 0..<100 {
				if try c.status().queue == 1 {
					queued = true
					break
				}
				usleep(20_000)
			}
			#expect(queued)
			try c.release(first.id)
			let second = try result.wait(seconds: 5).get()
			#expect(second.id == "L2")
			#expect(second.capsule == first.capsule)
		}
	}

	@Test func queuedLeaseTimesOut() throws {
		try withBay(capacity: 1) { bay in
			let c = unixClient(bay)
			_ = try c.createLease(LeaseRequest(waitS: 0))
			let t0 = nowSeconds()
			let (e, _) = try #require(apiError { _ = try c.createLease(LeaseRequest(waitS: 1)) })
			#expect(e.code == APIError.noCapacity)
			#expect(nowSeconds() - t0 >= 0.9)
			#expect(try c.status().queue == 0)
		}
	}

	@Test func tcpWithToken() throws {
		try withBay(tcp: true) { bay in
			let port = try #require(bay.tcpPort)
			let token = try #require(bay.token)
			let good = CryoClient(target: CryoTarget(endpoint: .tcp(host: "127.0.0.1", port: port), token: token))
			let l = try good.createLease(LeaseRequest(waitS: 0))
			#expect(try good.listLeases() == [l])

			let bad = CryoClient(target: CryoTarget(endpoint: .tcp(host: "127.0.0.1", port: port), token: "wrong"))
			let (e, status) = try #require(apiError { _ = try bad.status() })
			#expect(e.code == APIError.unauthorized)
			#expect(status == 401)

			let none = CryoClient(target: CryoTarget(endpoint: .tcp(host: "127.0.0.1", port: port)))
			#expect(apiError { _ = try none.status() }?.0.code == APIError.unauthorized)

			// The unix socket needs no token.
			#expect(try unixClient(bay).listLeases() == [l])
		}
	}

	@Test func upgradeRequired() throws {
		try withBay { bay in
			bay.requireMinimumClientVersion = 2
			let c = unixClient(bay)
			do {
				_ = try c.status()
				Issue.record("expected upgradeRequired")
			} catch CryoClientError.upgradeRequired(let m) {
				#expect(m.contains("older"))
			} catch {
				Issue.record("wrong error \(error)")
			}
			bay.requireMinimumClientVersion = nil
			_ = try c.status()
		}
	}

	@Test func connectEchoRoundTrip() throws {
		let echo = EchoServer()
		try echo.start()
		defer { echo.stop() }
		try withBay { bay in
			bay.sshdPort = echo.port
			let c = unixClient(bay)
			let l = try c.createLease(LeaseRequest(waitS: 0))
			let stream = try c.connect(l.id)
			try stream.writeAll(Array("hello ssh".utf8))
			#expect(String(decoding: try stream.readExactly(9), as: UTF8.self) == "hello ssh")
			stream.shutdownWrite()
			#expect(try stream.read().isEmpty)
			stream.close()

			let (e, status) = try #require(apiError { _ = try c.connect("nope") })
			#expect(e.code == APIError.notFound && status == 404)
		}
	}

	@Test func idleIsCappedAtADay() throws {
		try withBay(capacity: 3) { bay in
			let c = unixClient(bay)
			let short = try c.createLease(LeaseRequest(waitS: 0, idleS: 300))
			let long = try c.createLease(LeaseRequest(waitS: 0, idleS: 999_999))
			#expect(short.idleS == 300)
			#expect(long.idleS == 86400)
			#expect(try c.createLease(LeaseRequest(waitS: 0, idleS: 0)).idleS == 1)  // the real bay's floor
		}
	}

	@Test func connectWithoutSSHDIsCapsuleUnreachable() throws {
		try withBay { bay in
			let c = unixClient(bay)
			let l = try c.createLease(LeaseRequest(waitS: 0))
			let (e, status) = try #require(apiError { _ = try c.connect(l.id) })
			#expect(e.code == APIError.capsuleUnreachable && status == 503)
		}
	}

	@Test func pipeCopiesBothWays() throws {
		let echo = EchoServer()
		try echo.start()
		defer { echo.stop() }
		try withBay { bay in
			bay.sshdPort = echo.port
			let c = unixClient(bay)
			let l = try c.createLease(LeaseRequest(waitS: 0))
			let stream = try c.connect(l.id)

			var a: [Int32] = [0, 0]
			var b: [Int32] = [0, 0]
			#expect(pipe(&a) == 0 && pipe(&b) == 0)
			let inPipe = a
			let outPipe = b
			let payload = [UInt8]((0..<200_000).map { UInt8($0 % 251) })
			let done = ResultBox<Void>()
			spawnThread {
				done.set(Result { try pipe(stream, stdinFD: inPipe[0], stdoutFD: outPipe[1]) })
				close(outPipe[1])
			}
			let writer = ResultBox<Void>()
			spawnThread {
				payload.withUnsafeBytes { raw in
					var off = 0
					while off < raw.count {
						let n = write(inPipe[1], raw.baseAddress! + off, raw.count - off)
						if n <= 0 { break }
						off += n
					}
				}
				close(inPipe[1])  // stdin EOF -> half-close
				writer.set(.success(()))
			}
			var got: [UInt8] = []
			var chunk = [UInt8](repeating: 0, count: 65536)
			while true {
				let n = chunk.withUnsafeMutableBytes { read(outPipe[0], $0.baseAddress, $0.count) }
				if n <= 0 { break }
				got += chunk[0..<n]
			}
			#expect(got == payload)
			try done.wait(seconds: 5).get()
			_ = try writer.wait(seconds: 5)
			close(inPipe[0])
			close(outPipe[0])
		}
	}
}

@Suite struct HelperTests {
	@Test func proxyCommandQuotesForTheShellAndSSH() {
		#expect(sshProxyCommand(executable: "/opt/cryo/bin/cryo", leaseID: "L1") == "/opt/cryo/bin/cryo ssh L1")
		#expect(sshProxyCommand(executable: "/Users/a b/it's%/cryo", leaseID: "L2") == #"'/Users/a b/it'\''s%%/cryo' ssh L2"#)
	}

	@Test func writeAllWritesEverythingOrThrows() throws {
		var fds: [Int32] = [-1, -1]
		#expect(pipe(&fds) == 0)
		try writeAll(fds[1], Array("hello".utf8))
		writeAll(fds[1], " world")
		close(fds[1])
		var buf = [UInt8](repeating: 0, count: 64)
		let n = read(fds[0], &buf, buf.count)
		#expect(String(decoding: buf[0..<max(n, 0)], as: UTF8.self) == "hello world")
		close(fds[0])
		#expect(throws: SocketError.self) { try writeAll(-1, [1]) }
		#expect(currentDirectory().hasPrefix("/"))
	}
}

/// One-shot cross-thread result.
final class ResultBox<T: Sendable>: @unchecked Sendable {
	private let m = Monitor()
	private var value: Result<T, Error>?

	func set(_ r: Result<T, Error>) {
		m.withLock {
			value = r
			m.broadcast()
		}
	}

	func wait(seconds: Double) throws -> Result<T, Error> {
		let deadline = nowSeconds() + seconds
		m.lock()
		defer { m.unlock() }
		while value == nil {
			if !m.wait(until: deadline) { break }
		}
		guard let v = value else { throw SocketError("timed out waiting for thread") }
		return v
	}
}

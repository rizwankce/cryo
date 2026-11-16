#if canImport(FoundationEssentials)
	import FoundationEssentials
#else
	import Foundation
#endif

public struct SocketError: Error, CustomStringConvertible, Sendable {
	public enum Kind: Sendable { case failed, timeout, eof }
	public let kind: Kind
	public let message: String
	public var description: String { message }

	public init(_ what: String, errno e: Int32? = nil, kind: Kind = .failed) {
		self.kind = kind
		if let e { message = "\(what): \(String(cString: strerror(e)))" } else { message = what }
	}
}

#if canImport(Glibc)
	private let sockStream = Int32(SOCK_STREAM.rawValue)
#else
	private let sockStream = SOCK_STREAM
#endif

#if canImport(Darwin)
	private let sendFlags: Int32 = 0
#else
	private let sendFlags = Int32(MSG_NOSIGNAL)
#endif

private func makeSocket(_ family: Int32) throws -> Int32 {
	let fd = socket(family, sockStream, 0)
	if fd < 0 { throw SocketError("socket", errno: errno) }
	_ = fcntl(fd, F_SETFD, FD_CLOEXEC)
	#if canImport(Darwin)
		var one: Int32 = 1
		setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
	#endif
	return fd
}

private func unixAddress(_ path: String) throws -> sockaddr_un {
	var addr = sockaddr_un()
	addr.sun_family = sa_family_t(AF_UNIX)
	let bytes = Array(path.utf8)
	let cap = MemoryLayout.size(ofValue: addr.sun_path)
	guard !bytes.isEmpty, bytes.count < cap else {
		throw SocketError("unix socket path too long or empty (max \(cap - 1) bytes): \(path)")
	}
	withUnsafeMutableBytes(of: &addr.sun_path) { raw in
		for (i, b) in bytes.enumerated() { raw[i] = b }
		raw[bytes.count] = 0
	}
	return addr
}

/// A connected stream socket with a read buffer (so bytes read past an HTTP header are not lost).
/// One reader and one writer thread at a time are fine; concurrent readers are not.
public final class Socket: @unchecked Sendable {
	public let fd: Int32
	private var buffer: [UInt8] = []
	private var start = 0
	private var closed = false

	public init(fd: Int32) { self.fd = fd }
	deinit { close() }

	public static func connectUnix(path: String) throws -> Socket {
		var addr = try unixAddress(path)
		let fd = try makeSocket(AF_UNIX)
		let rc = withUnsafePointer(to: &addr) {
			$0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
				connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
			}
		}
		if rc != 0 {
			let e = errno
			_ = sysClose(fd)
			throw SocketError("connect \(path)", errno: e)
		}
		return Socket(fd: fd)
	}

	/// `timeout` bounds the whole connect (every address `host` resolves to); a blocking connect to
	/// a host that is down waits the kernel's ~75 s instead.
	public static func connectTCP(host: String, port: Int, timeout: Double = 10) throws -> Socket {
		var hints = addrinfo()
		hints.ai_family = AF_UNSPEC
		#if canImport(Glibc)
			hints.ai_socktype = Int32(SOCK_STREAM.rawValue)
		#else
			hints.ai_socktype = SOCK_STREAM
		#endif
		var res: UnsafeMutablePointer<addrinfo>?
		let rc = getaddrinfo(host, String(port), &hints, &res)
		guard rc == 0, let first = res else {
			throw SocketError("resolve \(host): \(String(cString: gai_strerror(rc)))")
		}
		defer { freeaddrinfo(first) }
		let deadline = nowSeconds() + timeout
		var lastErr: Int32 = ECONNREFUSED
		var p: UnsafeMutablePointer<addrinfo>? = first
		while let ai = p {
			if let fd = try? makeSocket(ai.pointee.ai_family) {
				let e = connectBounded(fd, ai.pointee.ai_addr, ai.pointee.ai_addrlen, deadline: deadline)
				if e == 0 { return Socket(fd: fd) }
				lastErr = e
				_ = sysClose(fd)
				if e == ETIMEDOUT, nowSeconds() >= deadline { break }
			}
			p = ai.pointee.ai_next
		}
		if lastErr == ETIMEDOUT {
			throw SocketError("connect \(host):\(port): timed out after \(timeout) s", kind: .timeout)
		}
		throw SocketError("connect \(host):\(port)", errno: lastErr)
	}

	/// Non-blocking connect, then poll until `deadline`; the socket is blocking again afterwards.
	/// Returns 0 or the errno (ETIMEDOUT when the deadline passes).
	private static func connectBounded(_ fd: Int32, _ addr: UnsafeMutablePointer<sockaddr>?, _ len: socklen_t, deadline: Double) -> Int32 {
		let flags = fcntl(fd, F_GETFL, 0)
		_ = fcntl(fd, F_SETFL, flags | O_NONBLOCK)
		defer { _ = fcntl(fd, F_SETFL, flags) }
		if connect(fd, addr, len) == 0 { return 0 }
		let e = errno
		guard e == EINPROGRESS || e == EINTR else { return e }
		while true {
			let left = deadline - nowSeconds()
			if left <= 0 { return ETIMEDOUT }
			var p = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
			let n = poll(&p, 1, Int32(min(left * 1000, Double(Int32.max)).rounded(.up)))
			if n < 0 {
				if errno == EINTR { continue }
				return errno
			}
			if n == 0 { return ETIMEDOUT }
			var soErr: Int32 = 0
			var size = socklen_t(MemoryLayout<Int32>.size)
			if getsockopt(fd, SOL_SOCKET, SO_ERROR, &soErr, &size) != 0 { return errno }
			return soErr
		}
	}

	/// Receive and send timeouts in seconds (0 = none).
	public func setTimeouts(receive: Int, send: Int? = nil) {
		var tv = timeval(tv_sec: receive, tv_usec: 0)
		setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
		var tv2 = timeval(tv_sec: send ?? receive, tv_usec: 0)
		setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv2, socklen_t(MemoryLayout<timeval>.size))
	}

	/// Idempotent.
	public func close() {
		if closed { return }
		closed = true
		_ = sysClose(fd)
	}

	public func shutdownWrite() { _ = shutdown(fd, Int32(SHUT_WR)) }
	public func shutdownBoth() { _ = shutdown(fd, Int32(SHUT_RDWR)) }

	// MARK: reading

	public var hasPending: Bool { start < buffer.count }

	/// Returns and clears bytes already buffered.
	public func takePending() -> [UInt8] {
		let out = Array(buffer[start...])
		buffer.removeAll()
		start = 0
		return out
	}

	private func fill() throws -> Bool {
		var chunk = [UInt8](repeating: 0, count: 16 * 1024)
		while true {
			let n = chunk.withUnsafeMutableBytes { recv(fd, $0.baseAddress, $0.count, 0) }
			if n > 0 {
				if start == buffer.count {
					buffer.removeAll(keepingCapacity: true)
					start = 0
				}
				buffer.append(contentsOf: chunk[0..<n])
				return true
			}
			if n == 0 { return false }
			let e = errno
			if e == EINTR { continue }
			if e == EAGAIN || e == EWOULDBLOCK { throw SocketError("timed out waiting for data", kind: .timeout) }
			throw SocketError("recv", errno: e)
		}
	}

	/// Up to `max` bytes (buffered ones first); empty array means EOF.
	public func read(max: Int = 64 * 1024) throws -> [UInt8] {
		if !hasPending, try !fill() { return [] }
		let n = min(max, buffer.count - start)
		let out = Array(buffer[start..<start + n])
		start += n
		return out
	}

	/// One line without its CRLF/LF; nil on EOF before any byte.
	public func readLine(maxLength: Int = 64 * 1024) throws -> String? {
		// Counted from `start`, not an index: `fill()` drops a fully read buffer and restarts at 0.
		var scanned = 0
		while true {
			if let i = buffer[(start + scanned)...].firstIndex(of: 0x0A) {
				var end = i
				if end > start, buffer[end - 1] == 0x0D { end -= 1 }
				if end - start > maxLength { throw SocketError("line too long") }
				let line = String(decoding: buffer[start..<end], as: UTF8.self)
				start = i + 1
				return line
			}
			scanned = buffer.count - start
			if scanned > maxLength { throw SocketError("line too long") }
			if try !fill() {
				if start == buffer.count { return nil }
				throw SocketError("connection closed mid-line", kind: .eof)
			}
		}
	}

	public func readExactly(_ n: Int) throws -> [UInt8] {
		var out: [UInt8] = []
		out.reserveCapacity(n)
		while out.count < n {
			let part = try read(max: n - out.count)
			if part.isEmpty { throw SocketError("connection closed before \(n) bytes arrived", kind: .eof) }
			out.append(contentsOf: part)
		}
		return out
	}

	public func readToEOF(limit: Int = 16 * 1024 * 1024) throws -> [UInt8] {
		var out: [UInt8] = []
		while true {
			let part = try read()
			if part.isEmpty { return out }
			out.append(contentsOf: part)
			if out.count > limit { throw SocketError("body too large") }
		}
	}

	// MARK: writing

	public func writeAll(_ bytes: [UInt8]) throws {
		try bytes.withUnsafeBytes { raw in
			var off = 0
			while off < raw.count {
				let n = send(fd, raw.baseAddress! + off, raw.count - off, sendFlags)
				if n >= 0 {
					off += n
					continue
				}
				let e = errno
				if e == EINTR { continue }
				throw SocketError("send", errno: e)
			}
		}
	}
}

/// Bytes both ways after an Upgrade; the same type as a plain connection.
public typealias ByteStream = Socket

/// A listening socket (unix path or TCP).
public final class Listener: @unchecked Sendable {
	public let fd: Int32
	/// TCP only: the bound port (useful with port 0).
	public let port: Int?
	public let path: String?
	private var closed = false

	init(fd: Int32, port: Int?, path: String?) {
		self.fd = fd
		self.port = port
		self.path = path
	}

	deinit { close() }

	/// Creates the socket file with mode 0600, replacing a stale one.
	public static func unix(path: String) throws -> Listener {
		var addr = try unixAddress(path)
		let fd = try makeSocket(AF_UNIX)
		unlink(path)
		let rc = withUnsafePointer(to: &addr) {
			$0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
				bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
			}
		}
		if rc != 0 || listen(fd, 64) != 0 {
			let e = errno
			_ = sysClose(fd)
			throw SocketError("listen \(path)", errno: e)
		}
		chmod(path, 0o600)
		return Listener(fd: fd, port: nil, path: path)
	}

	/// IPv4 only. `port` 0 picks an ephemeral port.
	public static func tcp(host: String = "127.0.0.1", port: Int = 0) throws -> Listener {
		let fd = try makeSocket(AF_INET)
		var one: Int32 = 1
		setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &one, socklen_t(MemoryLayout<Int32>.size))
		var addr = sockaddr_in()
		addr.sin_family = sa_family_t(AF_INET)
		addr.sin_port = UInt16(port).bigEndian
		guard inet_pton(AF_INET, host, &addr.sin_addr) == 1 else {
			_ = sysClose(fd)
			throw SocketError("not an IPv4 address: \(host)")
		}
		let rc = withUnsafePointer(to: &addr) {
			$0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
				bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
			}
		}
		if rc != 0 || listen(fd, 64) != 0 {
			let e = errno
			_ = sysClose(fd)
			throw SocketError("listen \(host):\(port)", errno: e)
		}
		var bound = sockaddr_in()
		var len = socklen_t(MemoryLayout<sockaddr_in>.size)
		_ = withUnsafeMutablePointer(to: &bound) {
			$0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &len) }
		}
		return Listener(fd: fd, port: Int(UInt16(bigEndian: bound.sin_port)), path: nil)
	}

	/// Waits up to `timeoutMs` for a connection; nil on timeout.
	public func accept(timeoutMs: Int32 = 100) throws -> Socket? {
		var p = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
		let n = poll(&p, 1, timeoutMs)
		if n == 0 { return nil }
		if n < 0 {
			if errno == EINTR { return nil }
			throw SocketError("poll", errno: errno)
		}
		let c = sysAccept(fd)
		if c < 0 {
			let e = errno
			if e == EINTR || e == EAGAIN || e == ECONNABORTED { return nil }
			throw SocketError("accept", errno: e)
		}
		_ = fcntl(c, F_SETFD, FD_CLOEXEC)
		#if canImport(Darwin)
			var one: Int32 = 1
			setsockopt(c, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
		#endif
		return Socket(fd: c)
	}

	public func close() {
		if closed { return }
		closed = true
		_ = sysClose(fd)
		if let path { unlink(path) }
	}
}

@inline(__always) private func sysClose(_ fd: Int32) -> Int32 { close(fd) }
@inline(__always) private func sysAccept(_ fd: Int32) -> Int32 { accept(fd, nil, nil) }

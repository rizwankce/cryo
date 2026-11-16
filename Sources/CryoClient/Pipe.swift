import CryoHTTP

/// Copies stdin to the stream and the stream to stdout until the stream closes. When stdin hits
/// EOF the write side of the stream is half-closed and the copy continues until the peer closes.
public func pipe(_ stream: ByteStream, stdinFD: Int32 = 0, stdoutFD: Int32 = 1) throws {
	if stream.hasPending { try writeAll(stdoutFD, stream.takePending()) }
	var stdinOpen = true
	var buf = [UInt8](repeating: 0, count: 64 * 1024)
	while true {
		var fds = [
			pollfd(fd: stream.fd, events: Int16(POLLIN), revents: 0),
			pollfd(fd: stdinFD, events: Int16(POLLIN), revents: 0),
		]
		let n = poll(&fds, stdinOpen ? 2 : 1, -1)
		if n < 0 {
			if errno == EINTR { continue }
			throw SocketError("poll", errno: errno)
		}
		if fds[0].revents != 0 {
			let data = try stream.read()
			if data.isEmpty { return }
			try writeAll(stdoutFD, data)
		}
		if stdinOpen, fds[1].revents != 0 {
			let r = buf.withUnsafeMutableBytes { read(stdinFD, $0.baseAddress, $0.count) }
			if r > 0 {
				try stream.writeAll(Array(buf[0..<r]))
			} else if r == 0 || (errno != EINTR && errno != EAGAIN) {
				stdinOpen = false
				stream.shutdownWrite()
			}
		}
	}
}

import CryoHTTP

/// A TCP server on 127.0.0.1 that echoes every byte back: a stand-in for a capsule's sshd.
public final class EchoServer: @unchecked Sendable {
	private let monitor = Monitor()
	private var listener: Listener?
	private var stopped = false
	public private(set) var port: Int = 0

	public init() {}

	public func start() throws {
		let l = try Listener.tcp(host: "127.0.0.1", port: 0)
		listener = l
		port = l.port ?? 0
		spawnThread { [self] in
			while !isStopped {
				guard let c = try? l.accept(timeoutMs: 50) else { continue }
				spawnThread {
					while let data = try? c.read(), !data.isEmpty {
						if (try? c.writeAll(data)) == nil { break }
					}
					c.shutdownWrite()
					c.close()
				}
			}
			l.close()
		}
	}

	private var isStopped: Bool { monitor.withLock { stopped } }

	public func stop() { monitor.withLock { stopped = true } }
}

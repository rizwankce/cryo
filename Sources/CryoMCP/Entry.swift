import CryoClient
import CryoHTTP

#if canImport(FoundationEssentials)
	import FoundationEssentials
#else
	import Foundation
#endif

/// Write end of the signal self-pipe. Only the signal handler touches it, with write(2).
nonisolated(unsafe) private var signalPipeWriteFD: Int32 = -1

private func onSignal(_ sig: Int32) {
	var b: UInt8 = UInt8(truncatingIfNeeded: sig)
	_ = write(signalPipeWriteFD, &b, 1)
}

/// `cryo mcp`: serves MCP on stdin/stdout until EOF, SIGINT, SIGTERM or SIGHUP; returns the exit code.
public func runMCPOnStdio(client: CryoClient, home: String, version: String) -> Int32 {
	var fds: [Int32] = [-1, -1]
	guard pipe(&fds) == 0 else {
		writeAll(2, "cryo mcp: cannot create pipe: \(String(cString: strerror(errno)))\n")
		return 1
	}
	for fd in fds {
		_ = fcntl(fd, F_SETFD, FD_CLOEXEC)
		_ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
	}
	signalPipeWriteFD = fds[1]
	signal(SIGPIPE, SIG_IGN)
	for sig in [SIGINT, SIGTERM, SIGHUP] { signal(sig, onSignal) }

	let server = MCPServer(
		client: client, local: LocalState(home: home), stopFD: fds[0], version: version,
		output: { writeAll(1, $0 + "\n") })
	server.serve()
	return 0
}

import CryoHTTP

#if canImport(FoundationEssentials)
	import FoundationEssentials
#else
	import Foundation
#endif

public struct CommandResult: Sendable, Equatable {
	public var exitCode: Int32
	public var stdout: String
	public var stderr: String
	public var timedOut: Bool
	/// True when the output was longer than the cap and only its tail is kept.
	public var stdoutTruncated: Bool
	public var stderrTruncated: Bool

	public init(
		exitCode: Int32, stdout: String = "", stderr: String = "", timedOut: Bool = false,
		stdoutTruncated: Bool = false, stderrTruncated: Bool = false
	) {
		self.exitCode = exitCode
		self.stdout = stdout
		self.stderr = stderr
		self.timedOut = timedOut
		self.stdoutTruncated = stdoutTruncated
		self.stderrTruncated = stderrTruncated
	}
}

/// Runs a local program. A protocol so tests can record argv instead of spawning ssh.
public protocol CommandRunner: Sendable {
	func run(argv: [String], timeout: Double) -> CommandResult
	/// Kills what `run` runs right now (from another thread), so those calls return at once.
	func cancelRunning()
}

extension CommandRunner {
	public func cancelRunning() {}
}

/// Counts `cancelRunning` calls; a run that sees the count change kills its child.
private final class CancelCount: @unchecked Sendable {
	private let m = Monitor()
	private var n = 0
	var value: Int { m.withLock { n } }
	func bump() { m.withLock { n += 1 } }
}

/// Keeps the last `cap` bytes of a stream.
struct TailBuffer {
	let cap: Int
	private(set) var bytes: [UInt8] = []
	private(set) var truncated = false

	init(cap: Int) { self.cap = cap }

	mutating func append(_ chunk: ArraySlice<UInt8>) {
		bytes.append(contentsOf: chunk)
		if bytes.count > cap * 2 { trim() }
	}

	mutating func finish() -> String {
		trim()
		return String(decoding: bytes, as: UTF8.self)
	}

	private mutating func trim() {
		if bytes.count > cap {
			bytes.removeFirst(bytes.count - cap)
			truncated = true
		}
	}
}

/// posix_spawnp with stdout and stderr pipes (read through poll), its own process group, and a
/// timeout that kills the whole group. `cancelRunning` kills the groups of the runs in progress.
public struct ProcessRunner: CommandRunner {
	public var outputCap: Int
	private let cancels = CancelCount()

	public init(outputCap: Int = 100 * 1024) { self.outputCap = outputCap }

	/// Each run notices within 100 ms (its poll interval) and kills its process group itself, so a
	/// pid is never signalled after it was reaped.
	public func cancelRunning() { cancels.bump() }

	public func run(argv: [String], timeout: Double) -> CommandResult {
		guard let program = argv.first else { return CommandResult(exitCode: 127, stderr: "no command\n") }
		let generation = cancels.value
		var outPipe: [Int32] = [-1, -1]
		var errPipe: [Int32] = [-1, -1]
		guard pipe(&outPipe) == 0 else { return failure(program, errno) }
		guard pipe(&errPipe) == 0 else {
			close(outPipe[0])
			close(outPipe[1])
			return failure(program, errno)
		}
		for fd in outPipe + errPipe { _ = fcntl(fd, F_SETFD, FD_CLOEXEC) }

		#if canImport(Darwin)
			var actions: posix_spawn_file_actions_t? = nil
			var attr: posix_spawnattr_t? = nil
		#else
			var actions = posix_spawn_file_actions_t()
			var attr = posix_spawnattr_t()
		#endif
		posix_spawn_file_actions_init(&actions)
		posix_spawnattr_init(&attr)
		defer {
			posix_spawn_file_actions_destroy(&actions)
			posix_spawnattr_destroy(&attr)
		}
		posix_spawn_file_actions_addopen(&actions, 0, "/dev/null", O_RDONLY, 0)
		posix_spawn_file_actions_adddup2(&actions, outPipe[1], 1)
		posix_spawn_file_actions_adddup2(&actions, errPipe[1], 2)
		posix_spawnattr_setpgroup(&attr, 0)
		// The child starts with default signal handling (this process ignores SIGPIPE, for one).
		var allSignals = sigset_t()
		sigfillset(&allSignals)
		var noSignals = sigset_t()
		sigemptyset(&noSignals)
		posix_spawnattr_setsigdefault(&attr, &allSignals)
		posix_spawnattr_setsigmask(&attr, &noSignals)
		posix_spawnattr_setflags(&attr, Int16(POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_SETSIGMASK))

		var cargs: [UnsafeMutablePointer<CChar>?] = argv.map { strdup($0) }
		cargs.append(nil)
		defer { for p in cargs { free(p) } }
		#if canImport(Darwin)
			// `_NSGetEnviron` and `environ` aren't visible to Swift on macOS; Foundation has the same values.
			var cenv: [UnsafeMutablePointer<CChar>?] = ProcessInfo.processInfo.environment.map { strdup("\($0.key)=\($0.value)") }
			cenv.append(nil)
			defer { for p in cenv { free(p) } }
		#elseif canImport(Musl)
			// Musl's `environ` is rejected by Swift 6 concurrency checking; our environment is never changed.
			var cenv: [UnsafeMutablePointer<CChar>?] = initialEnvironment().map { strdup($0) }
			cenv.append(nil)
			defer { for p in cenv { free(p) } }
		#else
			let env = environ
		#endif
		var pid: pid_t = 0
		#if canImport(Musl) || canImport(Darwin)
			let rc = posix_spawnp(&pid, program, &actions, &attr, cargs, cenv)
		#else
			let rc = posix_spawnp(&pid, program, &actions, &attr, cargs, env)
		#endif
		close(outPipe[1])
		close(errPipe[1])
		guard rc == 0 else {
			close(outPipe[0])
			close(errPipe[0])
			return failure(program, rc)
		}
		for fd in [outPipe[0], errPipe[0]] { _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK) }

		var out = TailBuffer(cap: outputCap)
		var err = TailBuffer(cap: outputCap)
		var fds = [outPipe[0], errPipe[0]]  // -1 once closed
		let deadline = nowSeconds() + timeout
		var timedOut = false
		var cancelled = false
		var status: Int32 = 0
		var exited = false
		var buf = [UInt8](repeating: 0, count: 64 * 1024)

		func drain(_ i: Int) {
			while fds[i] >= 0 {
				let n = read(fds[i], &buf, buf.count)
				if n > 0 {
					if i == 0 { out.append(buf[0..<n]) } else { err.append(buf[0..<n]) }
					continue
				}
				if n < 0 && errno == EINTR { continue }
				if n < 0 && (errno == EAGAIN || errno == EWOULDBLOCK) { return }
				close(fds[i])  // EOF or error
				fds[i] = -1
			}
		}

		while true {
			let remaining = deadline - nowSeconds()
			if remaining <= 0 {
				timedOut = true
				break
			}
			if cancels.value != generation {
				cancelled = true
				break
			}
			var pfds = [pollfd]()
			var which = [Int]()
			for i in 0..<2 where fds[i] >= 0 {
				pfds.append(pollfd(fd: fds[i], events: Int16(POLLIN), revents: 0))
				which.append(i)
			}
			if pfds.isEmpty {
				usleep(5_000)
			} else {
				_ = poll(&pfds, nfds_t(pfds.count), Int32(max(1, min(100, remaining * 1000))))
				for i in which { drain(i) }
			}
			if waitpid(pid, &status, WNOHANG) == pid {
				exited = true
				// A grandchild may still hold the pipes open; take what is there and stop.
				drain(0)
				drain(1)
				break
			}
		}
		if timedOut || cancelled {
			kill(-pid, SIGKILL)
			kill(pid, SIGKILL)
			drain(0)
			drain(1)
		}
		for i in 0..<2 where fds[i] >= 0 { close(fds[i]) }
		if !exited {
			while waitpid(pid, &status, 0) < 0 && errno == EINTR {}
		}
		let code: Int32 = (status & 0x7f) == 0 ? (status >> 8) & 0xff : 128 + (status & 0x7f)
		let o = out.finish()
		let e = err.finish()
		return CommandResult(
			exitCode: code, stdout: o, stderr: e, timedOut: timedOut,
			stdoutTruncated: out.truncated, stderrTruncated: err.truncated)
	}

	private func failure(_ program: String, _ code: Int32) -> CommandResult {
		CommandResult(exitCode: 127, stderr: "cannot run \(program): \(String(cString: strerror(code)))\n")
	}
}

#if canImport(Musl)
	/// The process's starting environment, from /proc/self/environ (NUL-separated).
	private func initialEnvironment() -> [String] {
		let fd = open("/proc/self/environ", O_RDONLY)
		if fd < 0 { return [] }
		defer { close(fd) }
		var data: [UInt8] = []
		var buf = [UInt8](repeating: 0, count: 16 * 1024)
		while true {
			let n = read(fd, &buf, buf.count)
			if n < 0 && errno == EINTR { continue }
			if n <= 0 { break }
			data.append(contentsOf: buf[0..<n])
		}
		return data.split(separator: 0).map { String(decoding: $0, as: UTF8.self) }
	}
#endif

/// Absolute path of this executable, so ssh can run `<self> ssh <id>` even when `cryo` is not on PATH.
public func currentExecutablePath() -> String {
	var buf = [CChar](repeating: 0, count: 4096)
	#if canImport(Darwin)
		var size = UInt32(buf.count)
		if _NSGetExecutablePath(&buf, &size) == 0 {
			var resolved = [CChar](repeating: 0, count: Int(PATH_MAX))
			if realpath(buf, &resolved) != nil { return cString(resolved) }
			return cString(buf)
		}
	#else
		let n = readlink("/proc/self/exe", &buf, buf.count - 1)
		if n > 0 { return String(decoding: buf[0..<n].map { UInt8(bitPattern: $0) }, as: UTF8.self) }
	#endif
	return "cryo"
}

#if canImport(Darwin)
	private func cString(_ chars: [CChar]) -> String {
		String(decoding: chars.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
	}
#endif

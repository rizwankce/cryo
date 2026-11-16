#if canImport(Glibc)
	@_exported import Glibc
#elseif canImport(Musl)
	@_exported import Musl
#elseif canImport(Darwin)
	@_exported import Darwin
#endif

#if canImport(FoundationEssentials)
	import FoundationEssentials
#else
	import Foundation
#endif

/// Wall clock seconds since the epoch.
public func nowSeconds() -> Double {
	var ts = timespec()
	clock_gettime(CLOCK_REALTIME, &ts)
	return Double(ts.tv_sec) + Double(ts.tv_nsec) / 1e9
}

/// A mutex plus condition variable (Synchronization.Mutex has no wait).
public final class Monitor: @unchecked Sendable {
	private let m: UnsafeMutablePointer<pthread_mutex_t>
	private let c: UnsafeMutablePointer<pthread_cond_t>

	public init() {
		m = .allocate(capacity: 1)
		c = .allocate(capacity: 1)
		pthread_mutex_init(m, nil)
		pthread_cond_init(c, nil)
	}

	deinit {
		pthread_cond_destroy(c)
		pthread_mutex_destroy(m)
		c.deallocate()
		m.deallocate()
	}

	public func lock() { pthread_mutex_lock(m) }
	public func unlock() { pthread_mutex_unlock(m) }
	public func broadcast() { pthread_cond_broadcast(c) }

	public func withLock<T>(_ body: () throws -> T) rethrows -> T {
		lock()
		defer { unlock() }
		return try body()
	}

	/// Waits (lock must be held). `deadline` is wall-clock seconds; nil waits indefinitely.
	/// Returns false on timeout.
	@discardableResult
	public func wait(until deadline: Double? = nil) -> Bool {
		guard let deadline else {
			pthread_cond_wait(c, m)
			return true
		}
		var ts = timespec()
		ts.tv_sec = Int(deadline)
		ts.tv_nsec = Int((deadline - Double(Int(deadline))) * 1e9)
		return pthread_cond_timedwait(c, m, &ts) != ETIMEDOUT
	}
}

private final class ThreadBox: @unchecked Sendable {
	let body: @Sendable () -> Void
	init(_ body: @escaping @Sendable () -> Void) { self.body = body }
}

/// Starts a detached pthread running `body`.
public func spawnThread(_ body: @escaping @Sendable () -> Void) {
	let box = Unmanaged.passRetained(ThreadBox(body)).toOpaque()
	#if canImport(Darwin)
		var tid: pthread_t? = nil
		let rc = pthread_create(
			&tid, nil,
			{ arg in
				Unmanaged<ThreadBox>.fromOpaque(arg).takeRetainedValue().body()
				return nil
			}, box)
		if rc == 0, let tid { pthread_detach(tid) }
	#elseif canImport(Musl)
		var tid: pthread_t? = nil
		let rc = pthread_create(
			&tid, nil,
			{ arg in
				Unmanaged<ThreadBox>.fromOpaque(arg!).takeRetainedValue().body()
				return nil
			}, box)
		if rc == 0, let tid { pthread_detach(tid) }
	#else
		var tid = pthread_t()
		let rc = pthread_create(
			&tid, nil,
			{ arg in
				Unmanaged<ThreadBox>.fromOpaque(arg!).takeRetainedValue().body()
				return nil
			}, box)
		if rc == 0 { pthread_detach(tid) }
	#endif
	if rc != 0 {
		Unmanaged<ThreadBox>.fromOpaque(box).release()
		fatalError("pthread_create failed: \(rc)")
	}
}

/// The path a LaunchAgent should run this binary from. Under Homebrew the binary resolves to a
/// versioned keg (`<prefix>/Cellar/cryo/1.2.3/bin/cryo`) that `brew upgrade` deletes, so it maps to
/// the prefix's `opt/cryo/bin/cryo` symlink, which follows upgrades. Any other path (such as
/// `~/.cryo/bin/cryo` from scripts/build-bay.sh) is already stable and comes back unchanged.
public func launchAgentExecutablePath(_ path: String) -> String {
	let parts = path.split(separator: "/", omittingEmptySubsequences: false)
	// …/Cellar/<formula>/<version>/bin/<tool>
	guard parts.count >= 6, parts[parts.count - 5] == "Cellar", parts[parts.count - 2] == "bin" else { return path }
	let prefix = parts[..<(parts.count - 5)].joined(separator: "/")
	return "\(prefix)/opt/\(parts[parts.count - 4])/bin/\(parts[parts.count - 1])"
}

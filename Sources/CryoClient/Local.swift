import CryoAPI
import CryoHTTP

#if canImport(FoundationEssentials)
	import FoundationEssentials
#else
	import Foundation
#endif

public struct FileError: Error, CustomStringConvertible {
	public let description: String
	public init(description: String) { self.description = description }
}

public func readTextFile(_ path: String) -> String? {
	let fd = open(path, O_RDONLY)
	if fd < 0 { return nil }
	defer { close(fd) }
	var data: [UInt8] = []
	var buf = [UInt8](repeating: 0, count: 16 * 1024)
	while true {
		let n = read(fd, &buf, buf.count)
		if n < 0 && errno == EINTR { continue }
		if n <= 0 { break }
		data.append(contentsOf: buf[0..<n])
	}
	return String(decoding: data, as: UTF8.self)
}

public func fileMode(_ path: String) -> mode_t? {
	var st = stat()
	return stat(path, &st) == 0 ? st.st_mode & 0o777 : nil
}

public func pathExists(_ path: String) -> Bool { fileMode(path) != nil }

/// Last modification, in seconds since 1970; nil when the file is not there.
func modifiedAt(_ path: String) -> Double? {
	var st = stat()
	guard stat(path, &st) == 0 else { return nil }
	#if canImport(Darwin)
		return Double(st.st_mtimespec.tv_sec)
	#else
		return Double(st.st_mtim.tv_sec)
	#endif
}

/// mkdir -p; `mode` applies to directories created here.
public func makeDirs(_ path: String, mode: mode_t) throws {
	var current = path.hasPrefix("/") ? "" : "."
	for part in path.split(separator: "/") {
		current += "/" + part
		if mkdir(current, mode) != 0 && errno != EEXIST {
			throw FileError(description: "cannot create \(current): \(String(cString: strerror(errno)))")
		}
	}
}

/// Writes every byte to `fd`, going on after short writes and EINTR.
public func writeAll(_ fd: Int32, _ bytes: [UInt8]) throws {
	try bytes.withUnsafeBytes { raw in
		var off = 0
		while off < raw.count {
			let n = write(fd, raw.baseAddress! + off, raw.count - off)
			if n >= 0 {
				off += n
				continue
			}
			if errno == EINTR { continue }
			throw SocketError("write", errno: errno)
		}
	}
}

/// Best effort, for stdout and stderr: nobody is left to tell when they are closed.
public func writeAll(_ fd: Int32, _ s: String) {
	try? writeAll(fd, Array(s.utf8))
}

/// The working directory, or `/` when it cannot be read.
public func currentDirectory() -> String {
	var buf = [CChar](repeating: 0, count: 4096)
	guard getcwd(&buf, buf.count) != nil else { return "/" }
	return String(decoding: buf.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
}

/// Creates or replaces a file that is never readable by others: opened with `mode` from the start.
public func writeSecretFile(_ path: String, _ content: String) throws {
	let fd = open(path, O_WRONLY | O_CREAT | O_TRUNC | O_CLOEXEC, 0o600)
	guard fd >= 0 else { throw FileError(description: "cannot write \(path): \(String(cString: strerror(errno)))") }
	defer { close(fd) }
	_ = fchmod(fd, 0o600)  // a pre-existing file keeps its old mode under O_TRUNC
	do { try writeAll(fd, Array(content.utf8)) } catch { throw FileError(description: "cannot write \(path): \(error)") }
}

/// Temp file in the same directory plus rename. Keeps the mode of an existing file, else `mode`.
public func writeAtomically(_ path: String, _ content: String, mode: mode_t = 0o600) throws {
	let tmp = "\(path).tmp.\(getpid())"
	let m = fileMode(path) ?? mode
	unlink(tmp)
	let fd = open(tmp, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, 0o600)
	guard fd >= 0 else { throw FileError(description: "cannot write \(tmp): \(String(cString: strerror(errno)))") }
	let ok = (try? writeAll(fd, Array(content.utf8))) != nil && fchmod(fd, m) == 0 && fsync(fd) == 0
	let e = errno
	close(fd)
	guard ok else {
		unlink(tmp)
		throw FileError(description: "cannot write \(tmp): \(String(cString: strerror(e)))")
	}
	guard rename(tmp, path) == 0 else {
		let e = errno
		unlink(tmp)
		throw FileError(description: "cannot replace \(path): \(String(cString: strerror(e)))")
	}
}

public func listDir(_ path: String) -> [String] {
	guard let d = opendir(path) else { return [] }
	defer { closedir(d) }
	var names: [String] = []
	while let e = readdir(d) {
		let name = withUnsafePointer(to: &e.pointee.d_name) {
			$0.withMemoryRebound(to: CChar.self, capacity: 256) { String(cString: $0) }
		}
		if name != "." && name != ".." { names.append(name) }
	}
	return names
}

/// Makes `path` absolute against `cwd` and resolves `.` and `..` lexically.
public func absolutePath(_ path: String, cwd: String) -> String {
	let full = path.hasPrefix("/") ? path : cwd + "/" + path
	var parts: [Substring] = []
	for c in full.split(separator: "/") {
		if c == "." { continue }
		if c == ".." {
			_ = parts.popLast()
			continue
		}
		parts.append(c)
	}
	return "/" + parts.joined(separator: "/")
}

// MARK: ssh_config blocks

public func beginMarker(_ id: String) -> String { "# cryo lease \(id)" }
public func endMarker(_ id: String) -> String { "# end cryo lease \(id)" }

func lines(_ text: String) -> [String] { text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init) }

/// `<executable> ssh <id>` as an ssh `ProxyCommand` value: the path quoted for the shell ssh runs
/// it in, and `%` doubled since ssh expands `%` tokens there.
public func sshProxyCommand(executable: String, leaseID id: String) -> String {
	let plain =
		!executable.isEmpty
		&& executable.utf8.allSatisfy { b in
			(b >= 0x30 && b <= 0x39) || (b >= 0x41 && b <= 0x5A) || (b >= 0x61 && b <= 0x7A) || b == 0x2F || b == 0x2E || b == 0x5F || b == 0x2D || b == 0x2B
		}
	let exe = plain ? executable : "'" + replacing(executable, "'", with: "'\\''") + "'"
	return replacing(exe, "%", with: "%%") + " ssh \(id)"
}

private func replacing(_ s: String, _ target: Character, with replacement: String) -> String {
	var out = ""
	for c in s { if c == target { out += replacement } else { out.append(c) } }
	return out
}

public func removingBlock(_ text: String, id: String) -> String {
	let ls = lines(text)
	guard let b = ls.firstIndex(of: beginMarker(id)), let e = ls[b...].firstIndex(of: endMarker(id)) else { return text }
	var out = ls
	out.removeSubrange(b...e)
	return removingBlock(out.joined(separator: "\n"), id: id)
}

public func addingBlock(_ text: String, id: String, config: String) -> String {
	var t = removingBlock(text, id: id)
	if !t.isEmpty && !t.hasSuffix("\n") { t += "\n" }
	var body = config
	while body.hasSuffix("\n") { body.removeLast() }
	return t + beginMarker(id) + "\n" + body + "\n" + endMarker(id) + "\n"
}

public func blockIDs(_ text: String) -> [String] {
	let prefix = "# cryo lease "
	return lines(text).compactMap { l in
		guard l.hasPrefix(prefix) else { return nil }
		let id = String(l.dropFirst(prefix.count))
		return id.isEmpty || id.contains(" ") ? nil : id
	}
}

public func blockHost(_ text: String, id: String) -> String? {
	let ls = lines(text)
	guard let b = ls.firstIndex(of: beginMarker(id)), let e = ls[b...].firstIndex(of: endMarker(id)) else { return nil }
	for l in ls[b..<e] {
		let t = l.trimmingSpaces()
		if t.hasPrefix("Host ") {
			return t.dropFirst(5).trimmingSpaces().split(separator: " ").first.map(String.init)
		}
	}
	return nil
}

extension StringProtocol {
	public func trimmingSpaces() -> String {
		var s = Substring(self)
		while let f = s.first, f == " " || f == "\t" || f == "\r" { s = s.dropFirst() }
		while let l = s.last, l == " " || l == "\t" || l == "\r" { s = s.dropLast() }
		return String(s)
	}
}

/// The files cryo keeps under `~/.cryo` and `~/.ssh`.
public struct LocalState: Sendable {
	public let home: String
	public init(home: String) { self.home = home }

	public var cryoDir: String { home + "/.cryo" }
	public var keysDir: String { cryoDir + "/keys" }
	public var sshConfig: String { cryoDir + "/ssh_config" }
	public var userSSHDir: String { home + "/.ssh" }
	public var userSSHConfig: String { userSSHDir + "/config" }
	public func keyPath(_ id: String) -> String { keysDir + "/" + id }
	/// One known_hosts file per lease, named by the lease's `ssh_config` (never `~/.ssh/known_hosts`).
	public var knownHostsDir: String { cryoDir + "/known_hosts" }
	public func knownHostsPath(_ id: String) -> String { knownHostsDir + "/" + id }
	/// Which bay each lease came from (`CryoTarget.display`), one file per lease. A lease without
	/// one (saved before these existed, or by a caller that does not say) is the default local bay's.
	public var leaseBaysDir: String { cryoDir + "/lease-bays" }
	public func leaseBayPath(_ id: String) -> String { leaseBaysDir + "/" + id }
	/// The bay `CRYO_URL` names when it is unset (`CryoTarget.defaultURL`).
	public var defaultBay: String { "unix://" + cryoDir + "/bay.sock" }

	/// Writes the lease's key, pinned host key and ssh_config block, and notes `bay` it came from.
	public func saveLease(_ l: Lease, bay: CryoTarget? = nil) throws {
		try makeDirs(cryoDir, mode: 0o700)
		if let bay {
			try makeDirs(leaseBaysDir, mode: 0o700)
			try writeAtomically(leaseBayPath(l.id), bay.display + "\n", mode: 0o600)
		} else {
			unlink(leaseBayPath(l.id))
		}
		try makeDirs(keysDir, mode: 0o700)
		try writeSecretFile(keyPath(l.id), l.ssh.key)
		if let hostKey = l.ssh.hostKey {
			try makeDirs(knownHostsDir, mode: 0o700)
			try writeAtomically(knownHostsPath(l.id), "\(l.ssh.host) \(hostKey)\n", mode: 0o600)
		}
		try withConfigLock {
			let current = readTextFile(sshConfig) ?? ""
			try writeAtomically(sshConfig, addingBlock(current, id: l.id, config: l.ssh.config), mode: 0o600)
		}
	}

	public func removeLease(_ id: String) {
		unlink(keyPath(id))
		unlink(knownHostsPath(id))
		unlink(leaseBayPath(id))
		withConfigLock {
			if let current = readTextFile(sshConfig) {
				let next = removingBlock(current, id: id)
				if next != current { try? writeAtomically(sshConfig, next) }
			}
		}
	}

	/// Holds an exclusive lock on `ssh_config.lock` around a read-modify-write of `ssh_config`, so
	/// leases saved or removed at the same moment (two agents, `cryo ci` with two capsules) don't
	/// drop each other's blocks. Without `~/.cryo` there is nothing to edit and no lock is taken.
	private func withConfigLock<T>(_ body: () throws -> T) rethrows -> T {
		let fd = open(sshConfig + ".lock", O_RDWR | O_CREAT | O_CLOEXEC, 0o600)
		defer { if fd >= 0 { close(fd) } }  // closing releases the lock
		if fd >= 0 { while flock(fd, LOCK_EX) != 0 && errno == EINTR {} }
		return try body()
	}

	/// Lease ids that have a key file, a known_hosts file, a bay record or a block locally.
	public func localIDs() -> Set<String> {
		var ids = Set((listDir(keysDir) + listDir(knownHostsDir) + listDir(leaseBaysDir)).filter { !$0.hasPrefix(".") && !$0.contains(".tmp.") })
		if let c = readTextFile(sshConfig) { ids.formUnion(blockIDs(c)) }
		return ids
	}

	/// The bay a local lease came from, as `CryoTarget.display`.
	public func bay(of id: String) -> String {
		guard let text = readTextFile(leaseBayPath(id)) else { return defaultBay }
		let b = text.trimmingSpaces().split(separator: "\n").first.map(String.init) ?? ""
		return b.isEmpty ? defaultBay : b
	}

	/// Removes the local files of `bay`'s leases that are not in `live` (what the bay just listed).
	/// Other bays' leases stay, and so do leases saved in the last `grace` seconds: a `cryo lease`
	/// may have saved one after the bay made its list. Returns the ids removed.
	@discardableResult
	public func forgetLeases(except live: Set<String>, on bay: CryoTarget, grace: Double = 10, now: Double = nowSeconds()) -> [String] {
		var gone: [String] = []
		for id in localIDs().subtracting(live).sorted() where self.bay(of: id) == bay.display {
			let saved = [keyPath(id), knownHostsPath(id), leaseBayPath(id)].compactMap(modifiedAt).max()
			if let saved, now - saved < grace { continue }
			removeLease(id)
			gone.append(id)
		}
		return gone
	}
	public func host(for id: String) -> String? {
		readTextFile(sshConfig).flatMap { blockHost($0, id: id) }
	}

	public var userConfigIncludesCryo: Bool {
		guard let t = readTextFile(userSSHConfig) else { return false }
		return includesCryo(t)
	}

	public func includesCryo(_ text: String) -> Bool {
		lines(text).contains { l in
			let t = l.trimmingSpaces()
			return t == "Include ~/.cryo/ssh_config" || t == "Include \(sshConfig)"
		}
	}
}

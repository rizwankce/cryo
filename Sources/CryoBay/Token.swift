import Foundation

extension BayPaths {
	/// The bearer token for the network listener (api.md "Auth"), mode 0600.
	public var token: URL { root.appending(path: "token") }
}

/// `~/.cryo/token`: 32 random bytes as hex. Only the TCP listener checks it; the unix socket is
/// protected by its file mode instead.
public enum BayToken {
	public static func load(_ paths: BayPaths) -> String? {
		guard let data = try? Data(contentsOf: paths.token), let s = String(data: data, encoding: .utf8) else { return nil }
		let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
		return t.isEmpty ? nil : t
	}

	/// The existing token, or a new one when missing or `rotate` is set.
	@discardableResult
	public static func create(_ paths: BayPaths, rotate: Bool = false) throws -> String {
		if !rotate, let t = load(paths) { return t }
		let token = generate()
		try write(token + "\n", to: paths.token)
		return token
	}

	public static func generate() -> String {
		var g = SystemRandomNumberGenerator()
		return (0..<32).map { _ in
			let b = UInt8.random(in: 0...255, using: &g)
			return (b < 16 ? "0" : "") + String(b, radix: 16)
		}.joined()
	}

	/// Written through a 0600 temp file and renamed, so the token is never readable by others,
	/// not even for a moment.
	private static func write(_ text: String, to url: URL) throws {
		let dir = url.deletingLastPathComponent()
		try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
		let tmp = url.path + ".tmp.\(getpid())"
		unlink(tmp)
		let fd = open(tmp, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, 0o600)
		guard fd >= 0 else { throw TokenError("cannot write \(tmp): \(String(cString: strerror(errno)))") }
		let bytes = Array(text.utf8)
		let n = bytes.withUnsafeBytes { Darwin.write(fd, $0.baseAddress, $0.count) }
		let ok = n == bytes.count && fsync(fd) == 0
		close(fd)
		guard ok, rename(tmp, url.path) == 0 else {
			unlink(tmp)
			throw TokenError("cannot write \(url.path)")
		}
	}

	/// `cryo bay token [--rotate]`.
	static func command(_ args: [String], paths: BayPaths, out: BayCommand.Writer) throws -> Int32 {
		out(try create(paths, rotate: args.contains("--rotate")) + "\n")
		return 0
	}
}

struct TokenError: Error, CustomStringConvertible {
	let description: String
	init(_ description: String) { self.description = description }
}

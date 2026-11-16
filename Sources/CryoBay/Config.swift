import Foundation

/// `~/.cryo/config.toml` (docs/spec/bay.md "Config"). A flat `key = value` subset of TOML: strings
/// in double quotes, integers bare, `true`/`false`, `#` comments. Missing keys keep their defaults.
public struct BayConfig: Sendable, Equatable {
	/// Digest of the image the capsules run; nil until an image is built.
	public var image: String?
	/// Seconds of no activity before a lease is released, unless the lease asks otherwise.
	public var idleTimeoutS = 3600
	/// Hard cap on any lease.
	public var maxLeaseS = 86400
	/// How long a lease request waits in the queue by default.
	public var waitDefaultS = 600
	/// Capsules on this Mac (Apple's limit is 2 running VMs).
	public var capsules = 2
	/// Thaw even when host checks that gate thawing fail (docs/spec/setup.md). For a dev Mac that
	/// isn't set up as a host; `cryo doctor` and `/v1/status` still report the failures.
	public var ignoreDoctor = false

	public init() {}

	public static func load(_ url: URL) throws -> BayConfig {
		guard FileManager.default.fileExists(atPath: url.path) else { return BayConfig() }
		return try parse(String(contentsOf: url, encoding: .utf8))
	}

	public static func parse(_ text: String) throws -> BayConfig {
		var c = BayConfig()
		for (n, raw) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
			let trimmed = stripComment(raw).trimmingCharacters(in: .whitespaces)
			if trimmed.isEmpty { continue }
			let kv = trimmed.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
			guard kv.count == 2 else { throw BayError("config.toml line \(n + 1): expected key = value") }
			let (key, value) = (kv[0], kv[1])
			func int() throws -> Int {
				guard let v = Int(value), v > 0 else { throw BayError("config.toml line \(n + 1): \(key) must be a positive integer") }
				return v
			}
			switch key {
			case "image":
				guard value.count >= 2, value.hasPrefix("\""), value.hasSuffix("\"") else {
					throw BayError("config.toml line \(n + 1): image must be a quoted string")
				}
				c.image = String(value.dropFirst().dropLast())
			case "idle_timeout_s": c.idleTimeoutS = try int()
			case "max_lease_s": c.maxLeaseS = try int()
			case "wait_default_s": c.waitDefaultS = try int()
			case "ignore_doctor":
				guard let v = Bool(value) else { throw BayError("config.toml line \(n + 1): ignore_doctor must be true or false") }
				c.ignoreDoctor = v
			case "capsules":
				c.capsules = try int()
				guard c.capsules <= 2 else { throw BayError("config.toml line \(n + 1): at most 2 capsules (Apple's VM limit)") }
			default: throw BayError("config.toml line \(n + 1): unknown key \(key)")
			}
		}
		return c
	}

	/// Drops a `#` comment that isn't inside a quoted string.
	static func stripComment(_ line: Substring) -> Substring {
		var quoted = false
		for i in line.indices {
			if line[i] == "\"" { quoted.toggle() }
			if line[i] == "#" && !quoted { return line[..<i] }
		}
		return line
	}

	public func text() -> String {
		var lines = ["# cryo bay config (docs/spec/bay.md)"]
		if let image { lines.append("image = \"\(image)\"") }
		lines.append("idle_timeout_s = \(idleTimeoutS)")
		lines.append("max_lease_s = \(maxLeaseS)")
		lines.append("wait_default_s = \(waitDefaultS)")
		lines.append("capsules = \(capsules)")
		if ignoreDoctor { lines.append("ignore_doctor = true") }
		return lines.joined(separator: "\n") + "\n"
	}

	public func save(_ url: URL) throws {
		try text().write(to: url, atomically: true, encoding: .utf8)
	}
}

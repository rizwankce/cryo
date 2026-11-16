import CryoHTTP

#if canImport(FoundationEssentials)
	import FoundationEssentials
#else
	import Foundation
#endif

public enum Endpoint: Sendable, Equatable {
	case unix(path: String)
	case tcp(host: String, port: Int)
}

/// Where the bay is: `CRYO_URL` (default `unix://~/.cryo/bay.sock`) plus optional `CRYO_TOKEN`.
public struct CryoTarget: Sendable, Equatable {
	public static let defaultURL = "unix://~/.cryo/bay.sock"

	public var endpoint: Endpoint
	public var token: String?

	public init(endpoint: Endpoint, token: String? = nil) {
		self.endpoint = endpoint
		self.token = token
	}

	/// Human-readable form, used in error messages.
	public var display: String {
		switch endpoint {
		case .unix(let p): return "unix://\(p)"
		case .tcp(let h, let p): return "http://\(h.contains(":") ? "[\(h)]" : h):\(p)"
		}
	}

	public init(url: String, token: String? = nil, home: String? = nil) throws {
		let home = home ?? currentHome()
		self.token = (token?.isEmpty ?? true) ? nil : token
		if url.hasPrefix("unix://") {
			var path = String(url.dropFirst("unix://".count))
			if path == "~" || path.hasPrefix("~/") {
				guard let home, !home.isEmpty else { throw CryoClientError.badTarget("\(url): HOME is not set, cannot expand ~") }
				path = home + path.dropFirst()
			}
			guard path.hasPrefix("/") else {
				throw CryoClientError.badTarget("\(url): unix path must be absolute (unix:///path) or start with ~/")
			}
			endpoint = .unix(path: path)
		} else if url.hasPrefix("https://") {
			throw CryoClientError.badTarget("TLS is not supported; use http:// on a trusted network (got \(url))")
		} else if url.hasPrefix("http://") {
			var rest = Substring(url.dropFirst("http://".count))
			if let slash = rest.firstIndex(of: "/") { rest = rest[..<slash] }
			var host = rest
			var port = 7477  // the bay's default listen port
			if rest.hasPrefix("[") {
				guard let close = rest.firstIndex(of: "]") else { throw CryoClientError.badTarget("\(url): bad IPv6 host") }
				host = rest[rest.index(after: rest.startIndex)..<close]
				let after = rest[rest.index(after: close)...]
				if after.hasPrefix(":") {
					guard let p = Int(after.dropFirst()) else { throw CryoClientError.badTarget("\(url): bad port") }
					port = p
				}
			} else if let colon = rest.lastIndex(of: ":") {
				host = rest[..<colon]
				guard let p = Int(rest[rest.index(after: colon)...]), (1...65535).contains(p) else {
					throw CryoClientError.badTarget("\(url): bad port")
				}
				port = p
			}
			guard !host.isEmpty else { throw CryoClientError.badTarget("\(url): missing host") }
			endpoint = .tcp(host: String(host), port: port)
		} else {
			throw CryoClientError.badTarget("\(url): expected unix:///path, unix://~/path or http://host[:7477]")
		}
	}

	/// Builds the target from an environment dictionary (`CRYO_URL`, `CRYO_TOKEN`, `HOME`).
	public init(environment env: [String: String]) throws {
		let url = env["CRYO_URL"].flatMap { $0.isEmpty ? nil : $0 } ?? CryoTarget.defaultURL
		try self.init(url: url, token: env["CRYO_TOKEN"], home: env["HOME"])
	}

	public static func fromProcessEnvironment() throws -> CryoTarget {
		var env: [String: String] = [:]
		for k in ["CRYO_URL", "CRYO_TOKEN", "HOME"] {
			if let v = getenv(k) { env[k] = String(cString: v) }
		}
		return try CryoTarget(environment: env)
	}
}

private func currentHome() -> String? {
	getenv("HOME").map { String(cString: $0) }
}

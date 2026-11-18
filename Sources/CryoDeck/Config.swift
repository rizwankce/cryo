import CryoClient
import Foundation

public struct DeckError: Error, CustomStringConvertible, Sendable {
	public let description: String
	public init(_ description: String) { self.description = description }
}

/// One bay the deck leases from.
public struct BayEntry: Sendable, Equatable {
	public var name: String
	public var url: String
	public var token: String

	public init(name: String, url: String, token: String) {
		self.name = name
		self.url = url
		self.token = token
	}

	/// Bay names are `[a-z0-9-]+`.
	public static func validName(_ name: String) -> Bool {
		!name.isEmpty && name.utf8.allSatisfy { ($0 >= 0x61 && $0 <= 0x7A) || ($0 >= 0x30 && $0 <= 0x39) || $0 == 0x2D }
	}
}

/// `deck.toml`: a minimal TOML subset (`key = "string"`, `[bay.<name>]` tables, `#` comments).
/// Read once when the deck starts; nothing watches the file.
public struct DeckConfig: Sendable, Equatable {
	/// Where the deck's network listener binds (`:7400`, `7400` or `host:port`); nil = the default.
	public var listen: String?
	public var bays: [BayEntry] = []

	public static let defaultListen = ":7400"

	public init(listen: String? = nil, bays: [BayEntry] = []) {
		self.listen = listen
		self.bays = bays
	}

	public static func load(_ url: URL) throws -> DeckConfig {
		guard FileManager.default.fileExists(atPath: url.path) else { return DeckConfig() }
		return try parse(String(contentsOf: url, encoding: .utf8))
	}

	public func save(_ url: URL) throws {
		try makeDirs(url.deletingLastPathComponent().path, mode: 0o700)
		try writeAtomically(url.path, text(), mode: 0o600)
		_ = chmod(url.path, 0o600)
	}

	public func bay(named name: String) -> BayEntry? { bays.first { $0.name == name } }

	public static func parse(_ text: String) throws -> DeckConfig {
		var config = DeckConfig()
		var current: (name: String, url: String?, token: String?, line: Int)?
		func finish() throws {
			guard let c = current else { return }
			guard let url = c.url else { throw DeckError("deck.toml line \(c.line): [bay.\(c.name)] has no url") }
			guard let token = c.token, !token.isEmpty else { throw DeckError("deck.toml line \(c.line): [bay.\(c.name)] has no token") }
			config.bays.append(BayEntry(name: c.name, url: url, token: token))
			current = nil
		}
		for (n, raw) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
			let line = n + 1
			let trimmed = stripComment(raw).trimmingCharacters(in: .whitespaces)
			if trimmed.isEmpty { continue }
			if trimmed.hasPrefix("[") {
				guard trimmed.hasSuffix("]"), trimmed.hasPrefix("[bay."), trimmed.count > 6 else {
					throw DeckError("deck.toml line \(line): expected a [bay.<name>] table")
				}
				let name = String(trimmed.dropFirst(5).dropLast())
				guard BayEntry.validName(name) else { throw DeckError("deck.toml line \(line): bay names use a-z, 0-9 and -, got '\(name)'") }
				try finish()
				if config.bays.contains(where: { $0.name == name }) { throw DeckError("deck.toml line \(line): bay '\(name)' is listed twice") }
				current = (name, nil, nil, line)
				continue
			}
			let kv = trimmed.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
			guard kv.count == 2 else { throw DeckError("deck.toml line \(line): expected key = \"value\"") }
			let key = kv[0]
			guard let value = unquote(kv[1]) else { throw DeckError("deck.toml line \(line): \(key) must be a quoted string") }
			if current == nil {
				guard key == "listen" else { throw DeckError("deck.toml line \(line): unknown key '\(key)'") }
				config.listen = value
			} else {
				switch key {
				case "url": current!.url = value
				case "token": current!.token = value
				default: throw DeckError("deck.toml line \(line): unknown key '\(key)' in [bay.\(current!.name)]")
				}
			}
		}
		try finish()
		return config
	}

	public func text() -> String {
		var s = "# cryo deck: the bays behind it. Read when the deck starts; restart the deck after editing.\n"
		if let listen { s += "listen = \(quote(listen))\n" }
		for b in bays {
			s += "\n[bay.\(b.name)]\nurl = \(quote(b.url))\ntoken = \(quote(b.token))\n"
		}
		return s
	}
}

private func quote(_ s: String) -> String {
	"\"" + s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
}

/// The text between the quotes (with `\\` and `\"` undone); nil when `s` is not one quoted string.
private func unquote(_ s: String) -> String? {
	guard s.count >= 2, s.hasPrefix("\""), s.hasSuffix("\"") else { return nil }
	var out = ""
	var escaped = false
	for c in s.dropFirst().dropLast() {
		if escaped {
			guard c == "\\" || c == "\"" else { return nil }
			out.append(c)
			escaped = false
		} else if c == "\\" {
			escaped = true
		} else if c == "\"" {
			return nil
		} else {
			out.append(c)
		}
	}
	return escaped ? nil : out
}

/// Drops a trailing `# comment` that is not inside a string.
private func stripComment(_ line: Substring) -> String {
	var inString = false
	var escaped = false
	var out = ""
	for c in line {
		if inString {
			if escaped {
				escaped = false
			} else if c == "\\" {
				escaped = true
			} else if c == "\"" {
				inString = false
			}
		} else if c == "\"" {
			inString = true
		} else if c == "#" {
			break
		}
		out.append(c)
	}
	return out
}

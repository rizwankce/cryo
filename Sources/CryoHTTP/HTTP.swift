#if canImport(FoundationEssentials)
	import FoundationEssentials
#else
	import Foundation
#endif

public enum HTTPError: Error, CustomStringConvertible, Sendable {
	case malformed(String)
	case unsupported(String)
	case tooLarge

	public var description: String {
		switch self {
		case .malformed(let s): return "malformed HTTP message: \(s)"
		case .unsupported(let s): return "unsupported HTTP feature: \(s)"
		case .tooLarge: return "HTTP body too large"
		}
	}
}

/// Ordered header list with case-insensitive lookup.
public struct HTTPHeaders: Sendable, Equatable {
	public private(set) var fields: [(name: String, value: String)] = []

	public init() {}

	public init(_ pairs: [(String, String)]) {
		for (n, v) in pairs { fields.append((n, v)) }
	}

	public subscript(name: String) -> String? {
		get {
			let l = name.lowercased()
			return fields.first { $0.name.lowercased() == l }?.value
		}
		set {
			let l = name.lowercased()
			fields.removeAll { $0.name.lowercased() == l }
			if let newValue { fields.append((name, newValue)) }
		}
	}

	public static func == (a: HTTPHeaders, b: HTTPHeaders) -> Bool {
		a.fields.count == b.fields.count && zip(a.fields, b.fields).allSatisfy { $0.name == $1.name && $0.value == $1.value }
	}
}

public struct HTTPRequest: Sendable {
	public var method: String
	/// Path plus optional `?query`.
	public var target: String
	public var headers: HTTPHeaders
	public var body: [UInt8]

	public init(method: String, target: String, headers: HTTPHeaders = HTTPHeaders(), body: [UInt8] = []) {
		self.method = method
		self.target = target
		self.headers = headers
		self.body = body
	}

	public var path: String {
		String(target.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false).first ?? "")
	}

	public var query: [String: String] {
		guard let q = target.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false).dropFirst().first else { return [:] }
		var out: [String: String] = [:]
		for pair in q.split(separator: "&") {
			let kv = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
			out[String(kv[0])] = kv.count > 1 ? String(kv[1]) : ""
		}
		return out
	}

	public func serialized() -> [UInt8] {
		var h = headers
		if !body.isEmpty || method == "POST" || method == "PUT" { h["Content-Length"] = String(body.count) }
		var out = Array("\(method) \(target) HTTP/1.1\r\n".utf8)
		for (n, v) in h.fields { out += Array("\(n): \(v)\r\n".utf8) }
		out += Array("\r\n".utf8)
		return out + body
	}
}

public struct HTTPResponse: Sendable {
	public var status: Int
	public var reason: String
	public var headers: HTTPHeaders
	public var body: [UInt8]

	public init(status: Int, reason: String? = nil, headers: HTTPHeaders = HTTPHeaders(), body: [UInt8] = []) {
		self.status = status
		self.reason = reason ?? HTTPResponse.defaultReason(status)
		self.headers = headers
		self.body = body
	}

	public static func defaultReason(_ status: Int) -> String {
		switch status {
		case 101: return "Switching Protocols"
		case 200: return "OK"
		case 201: return "Created"
		case 204: return "No Content"
		case 400: return "Bad Request"
		case 401: return "Unauthorized"
		case 404: return "Not Found"
		case 426: return "Upgrade Required"
		case 500: return "Internal Server Error"
		case 503: return "Service Unavailable"
		default: return "Status"
		}
	}

	/// Statuses that never carry a body.
	var bodyless: Bool { status == 101 || status == 204 || status == 304 || (100..<200).contains(status) }

	public func serialized() -> [UInt8] {
		var h = headers
		if !bodyless { h["Content-Length"] = String(body.count) }
		var out = Array("HTTP/1.1 \(status) \(reason)\r\n".utf8)
		for (n, v) in h.fields { out += Array("\(n): \(v)\r\n".utf8) }
		out += Array("\r\n".utf8)
		return bodyless ? out : out + body
	}
}

public enum HTTPWire {
	public static let maxBody = 16 * 1024 * 1024

	/// Reads a request; nil if the peer closed before sending anything.
	public static func readRequest(from s: Socket) throws -> HTTPRequest? {
		var first = try s.readLine()
		while first == "" { first = try s.readLine() }  // tolerate stray CRLF between requests
		guard let line = first else { return nil }
		let parts = line.split(separator: " ", omittingEmptySubsequences: true)
		guard parts.count == 3, parts[2].hasPrefix("HTTP/1.") else { throw HTTPError.malformed("bad request line") }
		let headers = try readHeaders(from: s)
		let body = try readBody(from: s, headers: headers, toEOF: false)
		return HTTPRequest(method: String(parts[0]), target: String(parts[1]), headers: headers, body: body)
	}

	/// Reads a response head and (unless 101/204) its body. For 101 the socket is left positioned
	/// at the first byte after the head.
	public static func readResponse(from s: Socket) throws -> HTTPResponse {
		guard let line = try s.readLine() else { throw HTTPError.malformed("connection closed before a response") }
		let parts = line.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true)
		guard parts.count >= 2, parts[0].hasPrefix("HTTP/1."), let status = Int(parts[1]) else {
			throw HTTPError.malformed("bad status line")
		}
		let headers = try readHeaders(from: s)
		var resp = HTTPResponse(status: status, reason: parts.count > 2 ? String(parts[2]) : nil, headers: headers)
		if !resp.bodyless { resp.body = try readBody(from: s, headers: headers, toEOF: true) }
		return resp
	}

	static func readHeaders(from s: Socket) throws -> HTTPHeaders {
		var h = HTTPHeaders()
		var count = 0
		while true {
			guard let line = try s.readLine() else { throw HTTPError.malformed("connection closed in headers") }
			if line.isEmpty { return h }
			count += 1
			if count > 200 { throw HTTPError.malformed("too many headers") }
			guard let colon = line.firstIndex(of: ":") else { throw HTTPError.malformed("bad header line") }
			let name = String(line[..<colon])
			let value = trim(String(line[line.index(after: colon)...]))
			h = appending(h, name, value)
		}
	}

	private static func appending(_ h: HTTPHeaders, _ n: String, _ v: String) -> HTTPHeaders {
		var out = h
		if let existing = out[n] { out[n] = existing + ", " + v } else { out[n] = v }
		return out
	}

	static func readBody(from s: Socket, headers: HTTPHeaders, toEOF: Bool) throws -> [UInt8] {
		if let te = headers["Transfer-Encoding"], te.lowercased() != "identity" {
			throw HTTPError.unsupported("Transfer-Encoding: \(te) (chunked bodies are not supported)")
		}
		if let cl = headers["Content-Length"] {
			guard let n = Int(trim(cl)), n >= 0 else { throw HTTPError.malformed("bad Content-Length") }
			if n > maxBody { throw HTTPError.tooLarge }
			return n == 0 ? [] : try s.readExactly(n)
		}
		return toEOF ? try s.readToEOF(limit: maxBody) : []
	}

	static func trim(_ s: String) -> String {
		var sub = Substring(s)
		while let f = sub.first, f == " " || f == "\t" { sub = sub.dropFirst() }
		while let l = sub.last, l == " " || l == "\t" || l == "\r" { sub = sub.dropLast() }
		return String(sub)
	}
}

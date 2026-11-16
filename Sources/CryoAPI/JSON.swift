#if canImport(FoundationEssentials)
	import FoundationEssentials
#else
	import Foundation
#endif

/// Encoder/decoder factories for the /v1 wire format: ISO8601 dates, sorted keys.
public enum CryoJSON {
	public static func encoder() -> JSONEncoder {
		let e = JSONEncoder()
		e.dateEncodingStrategy = .iso8601
		e.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
		return e
	}

	public static func decoder() -> JSONDecoder {
		let d = JSONDecoder()
		d.dateDecodingStrategy = .iso8601
		return d
	}
}

/// Any JSON value. Used for MCP, where payloads are not fixed Swift types.
public enum JSONValue: Codable, Sendable, Equatable {
	case null
	case bool(Bool)
	case number(Double)
	case string(String)
	case array([JSONValue])
	case object([String: JSONValue])

	public init(from decoder: Decoder) throws {
		let c = try decoder.singleValueContainer()
		if c.decodeNil() {
			self = .null
		} else if let v = try? c.decode(Bool.self) {
			self = .bool(v)
		} else if let v = try? c.decode(Double.self) {
			self = .number(v)
		} else if let v = try? c.decode(String.self) {
			self = .string(v)
		} else if let v = try? c.decode([JSONValue].self) {
			self = .array(v)
		} else if let v = try? c.decode([String: JSONValue].self) {
			self = .object(v)
		} else {
			throw DecodingError.dataCorruptedError(in: c, debugDescription: "not a JSON value")
		}
	}

	public func encode(to encoder: Encoder) throws {
		var c = encoder.singleValueContainer()
		switch self {
		case .null: try c.encodeNil()
		case .bool(let v): try c.encode(v)
		case .number(let v): try c.encode(v)
		case .string(let v): try c.encode(v)
		case .array(let v): try c.encode(v)
		case .object(let v): try c.encode(v)
		}
	}
}

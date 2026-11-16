import CryoAPI
import CryoHTTP

#if canImport(FoundationEssentials)
	import FoundationEssentials
#else
	import Foundation
#endif

/// Blocking client for the bay API. Each call opens its own connection.
public struct CryoClient: Sendable {
	public let target: CryoTarget
	/// Seconds to wait for any answer, except `createLease` which waits `wait_s` + `leaseMargin`.
	public var timeout: Int = 30
	public var leaseMargin: Int = 30
	/// Default `wait_s` of the bay (api.md: 600).
	public static let defaultWaitS = 600

	public init(target: CryoTarget) { self.target = target }

	public static func fromEnvironment() throws -> CryoClient {
		CryoClient(target: try CryoTarget.fromProcessEnvironment())
	}

	// MARK: API

	public func createLease(_ req: LeaseRequest) throws -> Lease {
		let wait = req.waitS ?? CryoClient.defaultWaitS
		let body = try CryoJSON.encoder().encode(req)
		return try call("POST", "/v1/leases", body: Array(body), timeout: wait + leaseMargin)
	}

	public func listLeases() throws -> [Lease] { try call("GET", "/v1/leases") }
	public func lease(_ id: String) throws -> Lease { try call("GET", "/v1/leases/\(encode(id))") }

	@discardableResult
	public func renew(_ id: String) throws -> RenewResponse {
		try call("POST", "/v1/leases/\(encode(id))/renew")
	}

	public func release(_ id: String, saveCache: Bool = false) throws {
		_ = try send("DELETE", "/v1/leases/\(encode(id))" + (saveCache ? "?save_cache=true" : ""))
	}

	public func status() throws -> Status { try call("GET", "/v1/status") }
	public func doctor() throws -> [DoctorCheck] { try call("GET", "/v1/doctor") }

	/// Upgrades to a raw byte stream to the capsule's sshd.
	public func connect(_ id: String) throws -> ByteStream {
		let sock = try open()
		do {
			var h = baseHeaders()
			h["Connection"] = "Upgrade"
			h["Upgrade"] = "cryo-ssh"
			try sock.writeAll(HTTPRequest(method: "POST", target: "/v1/leases/\(encode(id))/connect", headers: h).serialized())
			let resp = try readResponse(sock)
			guard resp.status == 101 else {
				throw mapError(resp)
			}
			sock.setTimeouts(receive: 0)  // a shell can stay silent for hours
			return sock
		} catch {
			sock.close()
			throw error
		}
	}

	// MARK: plumbing

	private func call<T: Decodable>(_ method: String, _ path: String, body: [UInt8]? = nil, timeout: Int? = nil) throws -> T {
		let resp = try send(method, path, body: body, timeout: timeout)
		do {
			return try CryoJSON.decoder().decode(T.self, from: Data(resp.body))
		} catch {
			throw CryoClientError.badResponse("cannot decode \(method) \(path): \(error)")
		}
	}

	func send(_ method: String, _ path: String, body: [UInt8]? = nil, timeout: Int? = nil) throws -> HTTPResponse {
		let sock = try open(timeout: timeout)
		defer { sock.close() }
		var h = baseHeaders()
		h["Connection"] = "close"
		if body != nil { h["Content-Type"] = "application/json" }
		do {
			try sock.writeAll(HTTPRequest(method: method, target: path, headers: h, body: body ?? []).serialized())
		} catch {
			throw CryoClientError.transport(target: target.display, message: "\(error)")
		}
		let resp = try readResponse(sock)
		guard (200..<300).contains(resp.status) else { throw mapError(resp) }
		return resp
	}

	private func baseHeaders() -> HTTPHeaders {
		var h = HTTPHeaders()
		h[apiVersionHeader] = String(apiVersion)
		h["Accept"] = "application/json"
		if let t = target.token { h["Authorization"] = "Bearer \(t)" }
		return h
	}

	private func open(timeout: Int? = nil) throws -> Socket {
		let sock: Socket
		do {
			switch target.endpoint {
			case .unix(let path): sock = try Socket.connectUnix(path: path)
			case .tcp(let host, let port): sock = try Socket.connectTCP(host: host, port: port)
			}
		} catch {
			throw CryoClientError.transport(target: target.display, message: "\(error)")
		}
		sock.setTimeouts(receive: timeout ?? self.timeout)
		return sock
	}

	private func readResponse(_ sock: Socket) throws -> HTTPResponse {
		let resp: HTTPResponse
		do {
			resp = try HTTPWire.readResponse(from: sock)
		} catch let e as HTTPError {
			throw CryoClientError.badResponse("\(e)")
		} catch {
			throw CryoClientError.transport(target: target.display, message: "\(error)")
		}
		guard resp.headers[apiVersionHeader] != nil else {
			throw CryoClientError.badResponse("missing \(apiVersionHeader) header — not a cryo bay? (HTTP \(resp.status))")
		}
		return resp
	}

	private func mapError(_ resp: HTTPResponse) -> CryoClientError {
		let api = try? CryoJSON.decoder().decode(APIError.self, from: Data(resp.body))
		if resp.status == 426 || api?.code == APIError.upgradeRequired {
			return .upgradeRequired(api?.message ?? "bay requires a newer client")
		}
		if let api { return .api(api, status: resp.status) }
		return .badResponse("HTTP \(resp.status) without an error envelope")
	}
}

private func encode(_ id: String) -> String {
	var out = ""
	for b in id.utf8 {
		let unreserved = (b >= 0x30 && b <= 0x39) || (b >= 0x41 && b <= 0x5A) || (b >= 0x61 && b <= 0x7A) || b == 0x2D || b == 0x2E || b == 0x5F || b == 0x7E
		if unreserved {
			out.unicodeScalars.append(Unicode.Scalar(b))
		} else {
			let hex = Array("0123456789ABCDEF")
			out += "%" + String(hex[Int(b >> 4)]) + String(hex[Int(b & 15)])
		}
	}
	return out
}

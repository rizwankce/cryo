import CryoAPI
import Foundation

/// The contract between the bay's API server (`Server.swift`, docs/spec/api.md) and the part that
/// owns capsules and leases (`Bay.swift`, docs/spec/bay.md). The server is thread-per-connection
/// with blocking sockets; the service lives on the main actor (Virtualization.framework). The
/// server bridges by awaiting these methods from its threads.
public protocol BayService: AnyObject, Sendable {
	/// `POST /v1/leases`. Waits in the first-come queue up to `wait_s` (config default when nil;
	/// 0 = fail at once). `viaNetwork`: the request came over the TCP listener, where a `folder` (a
	/// path on this Mac) is refused in v1 (no allow-list yet).
	func createLease(_ request: LeaseRequest, viaNetwork: Bool) async throws -> Lease
	/// `GET /v1/leases/{id}`.
	func lease(_ id: String) async throws -> Lease
	/// `GET /v1/leases`.
	func leases() async -> [Lease]
	/// `POST /v1/leases/{id}/renew`: activity; pushes `renew_by` out by the lease's idle timeout.
	func renew(_ id: String) async throws -> RenewResponse
	/// `DELETE /v1/leases/{id}`: stop, (save the cache), delete, refill. `404 not_found` if already gone.
	func release(_ id: String, saveCache: Bool) async throws
	/// `GET /v1/status`.
	func status() async -> Status
	/// `GET /v1/doctor`.
	func doctor() async -> [DoctorCheck]
	/// `POST /v1/leases/{id}/connect`: where the lease's guest sshd is. The server opens the TCP
	/// connection itself and reports it below; `503 capsule_unreachable` if it can't connect.
	func connectTarget(_ id: String) async throws -> (host: String, port: Int)
	/// An open `connect` stream counts as activity: a lease with an open connection never idles out
	/// (cli.md "Keeping a lease alive"). Opened/closed are balanced per connection.
	func connectionOpened(_ id: String) async
	func connectionClosed(_ id: String) async
}

/// An error the server turns into `{"error": {"code", "message"}}` with this HTTP status.
public struct ServiceError: Error, CustomStringConvertible, Sendable, Equatable {
	public var status: Int
	public var code: String
	public var message: String

	public init(_ status: Int, _ code: String, _ message: String) {
		self.status = status
		self.code = code
		self.message = message
	}

	public var description: String { "\(status) \(code): \(message)" }

	public static func notFound(_ id: String) -> ServiceError { ServiceError(404, APIError.notFound, "no lease \(id)") }
	public static func noCapacity(_ why: String) -> ServiceError { ServiceError(503, APIError.noCapacity, why) }
	public static func badRequest(_ why: String) -> ServiceError { ServiceError(400, APIError.badRequest, why) }
	public static func leaseLost(_ id: String, _ why: String) -> ServiceError { ServiceError(410, APIError.leaseLost, "lease \(id) lost: \(why)") }
	public static func `internal`(_ why: String) -> ServiceError { ServiceError(500, "internal", why) }
}

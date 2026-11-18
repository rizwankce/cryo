import CryoAPI
import CryoClient
import CryoHTTP

/// What the deck needs from one bay. `CryoClient` is the real one; tests can pass a fake, or point
/// the real client at in-process `FakeBay`s.
public protocol BayClient: Sendable {
	func status(timeout: Int) throws -> Status
	func listLeases() throws -> [Lease]
	func createLease(_ request: LeaseRequest) throws -> Lease
	func lease(_ id: String) throws -> Lease
	func renew(_ id: String) throws -> RenewResponse
	func release(_ id: String, saveCache: Bool) throws
	/// An upgraded stream to the lease's sshd (the 101 is already read).
	func connect(_ id: String) throws -> ByteStream
}

extension CryoClient: BayClient {
	public func status(timeout: Int) throws -> Status {
		var c = self
		c.timeout = timeout
		return try c.status()
	}
}

/// Makes the client for a bay entry. Throws when the URL is unusable.
public typealias BayClientFactory = @Sendable (BayEntry) throws -> any BayClient

public func defaultBayClient(_ entry: BayEntry) throws -> any BayClient {
	CryoClient(target: try CryoTarget(url: entry.url, token: entry.token))
}

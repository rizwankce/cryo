import CryoAPI
import CryoHTTP
import Foundation
import Testing

@testable import CryoServer

/// The bay's side of `connect` is unchanged by the deck: a service that does not override
/// `connectRoute` still gets its guest sshd as a TCP target.
@Suite struct ConnectRouteTests {
	@Test func theDefaultRouteIsTheTCPTargetOfConnectTarget() async throws {
		let service = FakeService()
		service.sshdPort = 4242
		let l = try await service.createLease(LeaseRequest(), viaNetwork: false)
		let route = try await service.connectRoute(l.id)
		guard case .tcp(let host, let port) = route else {
			Issue.record("expected a tcp route, got \(route)")
			return
		}
		#expect(host == "127.0.0.1" && port == 4242)
	}

	@Test func aLeaseThatIsGoneStillFailsLikeConnectTarget() async throws {
		let service = FakeService()
		do {
			_ = try await service.connectRoute("L9")
			Issue.record("expected an error")
		} catch let e as ServiceError {
			#expect(e == ServiceError.notFound("L9"))
		}
	}
}

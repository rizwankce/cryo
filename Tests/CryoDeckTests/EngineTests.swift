import CryoAPI
import CryoClient
import CryoDeck
import CryoHTTP
import CryoServer
import FakeBay
import Foundation
import Testing

// Serialized: tests block threads on client calls while the deck needs pool threads.
@Suite(.serialized) struct EngineTests {
	// MARK: ids and rewriting

	@Test func theFirstLeaseIsD1WithTheSSHConfigRewritten() async throws {
		try await withDeck { fx, _ in
			let l = try await fx.lease()
			#expect(l.id == "D1")
			#expect(l.state == "leased")
			#expect(l.ssh.host == "cryo-D1")
			#expect(l.ssh.user == "cryo")
			let cfg = l.ssh.config
			#expect(cfg.contains("Host cryo-D1\n"))
			#expect(cfg.contains("ProxyCommand cryo ssh D1\n"))
			#expect(cfg.contains("IdentityFile ~/.cryo/keys/D1\n"))
			#expect(cfg.contains("HostKeyAlias cryo-D1\n"))
			#expect(cfg.contains("UserKnownHostsFile ~/.cryo/known_hosts/D1\n"))
			#expect(!cfg.contains("L1"))
			// The keys are the bay's, untouched.
			#expect(l.ssh.key.contains("fake-key-L1"))
			#expect(l.ssh.hostKey == "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIFakeHostKeyL1")
		}
	}

	@Test func idsCountUpAcrossBays() async throws {
		try await withDeck { fx, _ in
			var ids: [String] = []
			for _ in 0..<3 { ids.append(try await fx.engineLease().id) }
			#expect(ids == ["D1", "D2", "D3"])
		}
	}

	@Test func aLeaseOnTheSecondBayKeepsItsBayLocalNumberAndGetsADeckCapsuleNumber() async throws {
		try await withDeck(bays: 2, capacity: 2) { fx, _ in
			let a = try await fx.engineLease()
			let b = try await fx.engineLease()
			#expect(a.capsule == 0)
			// The second bay's capsule 0 comes after the first bay's two capsules.
			#expect(b.capsule == 2)
			#expect(fx.bays[1].leases.first?.capsule == 0)
		}
	}

	// MARK: picking a bay

	@Test func roundRobinAlternatesBays() async throws {
		try await withDeck(bays: 2, capacity: 2) { fx, _ in
			var counts: [[Int]] = []
			for _ in 0..<4 {
				_ = try await fx.engineLease()
				counts.append(fx.bays.map(\.leases.count))
			}
			#expect(counts == [[1, 0], [1, 1], [2, 1], [2, 2]])
			// Everything is taken: a request that won't wait fails at once.
			let full = await serviceError { try await fx.engineLease(LeaseRequest(waitS: 0)) }
			#expect(full?.status == 503 && full?.code == APIError.noCapacity)
			#expect(full?.message == "no free capsule on any bay")
		}
	}

	@Test func roundRobinSpreadsThreeBays() async throws {
		try await withDeck(bays: 3, capacity: 2) { fx, _ in
			for _ in 0..<3 { _ = try await fx.engineLease() }
			#expect(fx.bays.map(\.leases.count) == [1, 1, 1])
		}
	}

	@Test func aBayWithNoThawedCapsuleIsSkipped() async throws {
		try await withDeck(bays: 2, capacity: 1) { fx, _ in
			// Someone else takes the first bay's only capsule, straight from the bay.
			let direct = fx.bayClient(0)
			_ = try await blocking { try direct.createLease(LeaseRequest()) }
			await fx.engine.pollOnce()
			let l = try await fx.engineLease()
			#expect(fx.bays[1].leases.count == 1)
			#expect(fx.bays[0].leases.count == 1)
			// Capsule 0 of the second bay, numbered after the first bay's one capsule.
			#expect(l.capsule == 1)
		}
	}

	@Test func aBayAnsweringNoCapacityIsSkippedForTheNextOne() async throws {
		try await withManualDeck(bays: 2, capacity: 1) { fx, _ in
			// The deck's last look says the first bay is free; it is not.
			let direct = fx.bayClient(0)
			_ = try await blocking { try direct.createLease(LeaseRequest()) }
			let l = try await fx.engineLease()
			#expect(l.id == "D1")
			#expect(fx.bays[1].leases.count == 1)
			// The deck asked the full bay, and asked it not to queue.
			#expect(fx.bays[0].lastLeaseRequest?.waitS == 0)
			#expect(fx.bays[0].leases.count == 1)
		}
	}

	@Test func aBayThatCannotBeReachedForALeaseIsSkippedLikeAFullOne() async throws {
		try await withManualDeck(bays: 2, capacity: 1) { fx, gates in
			gates[0].failCalls = true
			let l = try await fx.engineLease(LeaseRequest(waitS: 0))
			#expect(l.ssh.host == "cryo-D1")
			#expect(fx.bays[1].leases.count == 1)
			#expect(fx.bays[0].leases.isEmpty)
			// The second bay is now full and the first still does not answer.
			let err = await serviceError { try await fx.engineLease(LeaseRequest(waitS: 0)) }
			#expect(err?.code == APIError.noCapacity)
		}
	}

	@Test func requestFieldsReachTheBayAndTheBayIsToldNotToWait() async throws {
		try await withDeck(bays: 1) { fx, _ in
			let l = try await fx.lease(LeaseRequest(cache: "app", waitS: 30, name: "job", idleS: 120))
			let sent = try #require(fx.bays[0].lastLeaseRequest)
			#expect(sent.cache == "app" && sent.name == "job" && sent.idleS == 120)
			#expect(sent.waitS == 0)
			#expect(sent.folder == nil)
			#expect(l.name == "job" && l.cache == "app" && l.idleS == 120)
		}
	}

	@Test func aFolderIsRefusedBeforeAnyBayIsAsked() async throws {
		try await withDeck { fx, _ in
			let f = try await fx.failure { _ = try $0.createLease(LeaseRequest(folder: "/Users/me/repo")) }
			#expect(f?.status == 400 && f?.code == APIError.badRequest)
			#expect(f?.message.contains("--folder doesn't work through a deck") == true)
			#expect(f?.message.contains("git clone or copy_in") == true)
			#expect(fx.bays.allSatisfy { $0.lastLeaseRequest == nil })
			let direct = await serviceError { try await fx.engineLease(LeaseRequest(folder: "x")) }
			#expect(direct?.status == 400)
		}
	}

	@Test func aBayThatIsTooNewForTheDeckIsA502() async throws {
		try await withManualDeck(bays: 1) { fx, _ in
			fx.bays[0].requireMinimumClientVersion = 99
			let f = try await fx.failure { _ = try $0.createLease(LeaseRequest(waitS: 0)) }
			#expect(f?.status == 502 && f?.code == "bay_incompatible")
		}
	}

	@Test func theDefaultWaitApplies() async throws {
		var settings = DeckEngine.Settings()
		settings.defaultWaitS = 3
		try await withManualDeck(bays: 1, capacity: 1, settings: settings) { fx, _ in
			_ = try await fx.engineLease()
			let clock = try #require(fx.clock)
			let done = Flag()
			let engine = fx.engine
			let t = Task { () -> ServiceError? in
				let e = await serviceError { try await engine.createLease(LeaseRequest(), viaNetwork: false) }
				done.set()
				return e
			}
			#expect(await pump(clock, step: 1) { done.isSet })
			#expect(await t.value?.code == APIError.noCapacity)
		}
	}

	// MARK: the rest of a lease's life

	@Test func getReturnsTheLeaseWithTheDeckIDAndCapsule() async throws {
		try await withDeck { fx, _ in
			_ = try await fx.lease()
			let b = try await fx.lease()
			let c = fx.client()
			let got = try await blocking { try c.lease("D2") }
			#expect(got == b)
			#expect(got.capsule == 2)
		}
	}

	@Test func renewGoesToTheBayThatOwnsTheLease() async throws {
		try await withDeck { fx, _ in
			_ = try await fx.lease()
			_ = try await fx.lease()
			let c = fx.client()
			_ = try await blocking { try c.renew("D2") }
			#expect(fx.bays[1].renews == ["L1"])
			#expect(fx.bays[0].renews.isEmpty)
			_ = try await blocking { try c.renew("D1") }
			#expect(fx.bays[0].renews == ["L1"])
		}
	}

	@Test func releaseGoesToTheOwningBayWithTheBayLeaseID() async throws {
		try await withDeck { fx, _ in
			_ = try await fx.lease()
			_ = try await fx.lease()
			let c = fx.client()
			try await blocking { try c.release("D2", saveCache: true) }
			#expect(fx.bays[1].releases == [FakeBay.Release(id: "L1", saveCache: true)])
			#expect(fx.bays[0].releases.isEmpty)
			let again = try await fx.failure { _ = try $0.lease("D2") }
			#expect(again?.status == 410 && again?.code == APIError.leaseLost)
			let twice = try await fx.failure { try $0.release("D2") }
			#expect(twice?.status == 410)
			let list = try await blocking { try c.listLeases() }
			#expect(list.map(\.id) == ["D1"])
		}
	}

	@Test func releaseWithoutSaveCacheSaysSo() async throws {
		try await withDeck(bays: 1) { fx, _ in
			_ = try await fx.lease()
			let c = fx.client()
			try await blocking { try c.release("D1") }
			#expect(fx.bays[0].releases == [FakeBay.Release(id: "L1", saveCache: false)])
		}
	}

	@Test func listingShowsTheDecksLeasesOnly() async throws {
		try await withDeck { fx, _ in
			// A lease made straight on a bay is not the deck's.
			let direct = fx.bayClient(0)
			_ = try await blocking { try direct.createLease(LeaseRequest()) }
			await fx.engine.pollOnce()
			_ = try await fx.lease()
			_ = try await fx.lease()
			let c = fx.client()
			let list = try await blocking { try c.listLeases() }
			#expect(list.map(\.id) == ["D1", "D2"])
			#expect(list.map(\.ssh.host) == ["cryo-D1", "cryo-D2"])
			#expect(list[1].ssh.config.contains("cryo ssh D2"))
		}
	}

	@Test func listingIsInNumberOrderPastD9() async throws {
		try await withDeck(bays: 3, capacity: 4) { fx, _ in
			for _ in 0..<11 { _ = try await fx.engineLease() }
			let list = await fx.engine.leases()
			#expect(list.map(\.id) == (1...11).map { "D\($0)" })
		}
	}

	@Test func theSocketAndTheTCPPortServeTheSameDeck() async throws {
		try await withDeck(bays: 1) { fx, _ in
			let l = try await fx.lease(viaSocket: true)
			let c = fx.client()
			let got = try await blocking { try c.lease(l.id) }
			#expect(got == l)
		}
	}

	// MARK: leases that go away

	@Test func aLeaseTheBayLostIsLeaseLostAndForgotten() async throws {
		try await withDeck { fx, _ in
			_ = try await fx.lease()
			_ = try await fx.lease()
			fx.bays[0].loseLease("L1")
			let get = try await fx.failure { _ = try $0.lease("D1") }
			#expect(get?.status == 410 && get?.code == APIError.leaseLost)
			let renew = try await fx.failure { _ = try $0.renew("D1") }
			#expect(renew?.status == 410)
			let c = fx.client()
			let got1 = try await blocking { try c.listLeases() }.map(\.id)
			#expect(got1 == ["D2"])
			// The other lease is not affected.
			let got2 = try await blocking { try c.lease("D2") }.id
			#expect(got2 == "D2")
		}
	}

	@Test func aLeaseTheBayDoesNotKnowAnymoreIsLeaseLostToo() async throws {
		try await withDeck { fx, _ in
			_ = try await fx.lease()
			// Released on the bay behind the deck's back: the bay says 404 not_found.
			let direct = fx.bayClient(0)
			try await blocking { try direct.release("L1") }
			let get = try await fx.failure { _ = try $0.lease("D1") }
			#expect(get?.status == 410 && get?.code == APIError.leaseLost)
			let again = try await fx.failure { _ = try $0.lease("D1") }
			#expect(again?.status == 410)
		}
	}

	@Test func unknownIDsAreLeaseLostOnEveryRoute() async throws {
		try await withDeck { fx, _ in
			_ = try await fx.lease()
			for id in ["D99", "L1", "D0", "nonsense"] {
				let checks: [(String, APIFailure?)] = [
					("get", try await fx.failure { _ = try $0.lease(id) }),
					("renew", try await fx.failure { _ = try $0.renew(id) }),
					("release", try await fx.failure { try $0.release(id) }),
					("connect", try await fx.failure { _ = try $0.connect(id) }),
				]
				for (route, f) in checks {
					#expect(f?.status == 410 && f?.code == APIError.leaseLost, "\(route) \(id)")
				}
			}
			// The deck's own lease is untouched by all that.
			#expect(fx.bays[0].releases.isEmpty)
		}
	}

	@Test func aBayThatCannotBeReachedForALeaseIsA503AndTheLeaseIsKept() async throws {
		try await withManualDeck { fx, gates in
			_ = try await fx.lease()
			gates[0].failCalls = true
			for route in 0..<3 {
				let f = try await fx.failure {
					switch route {
					case 0: _ = try $0.lease("D1")
					case 1: _ = try $0.renew("D1")
					default: try $0.release("D1")
					}
				}
				#expect(f?.status == 503 && f?.code == "bay_unreachable", "route \(route)")
			}
			gates[0].failCalls = false
			let c = fx.client()
			let got3 = try await blocking { try c.lease("D1") }.id
			#expect(got3 == "D1")
		}
	}

	// MARK: access

	@Test func theTCPPortNeedsTheDeckToken() async throws {
		try await withDeck(bays: 1) { fx, _ in
			let port = fx.port
			let anon = CryoClient(target: CryoTarget(endpoint: .tcp(host: "127.0.0.1", port: port), token: nil))
			let wrong = CryoClient(target: CryoTarget(endpoint: .tcp(host: "127.0.0.1", port: port), token: "nope"))
			// A bay's own token is not the deck's token.
			let bayToken = CryoClient(target: CryoTarget(endpoint: .tcp(host: "127.0.0.1", port: port), token: fx.bays[0].token))
			for c in [anon, wrong, bayToken] {
				let f = await blocking2 { apiFailure { _ = try c.status() } }
				#expect(f?.status == 401 && f?.code == APIError.unauthorized)
			}
			// The socket needs none.
			let c = fx.client(viaSocket: true)
			let got4 = try await blocking { try c.status() }.queue
			#expect(got4 == 0)
		}
	}

	@Test func theDeckAcceptsLeaseRequestsFromTheNetworkWithoutAFolder() async throws {
		try await withDeck(bays: 1) { fx, _ in
			// `viaNetwork` is not a reason to refuse anything else a client sends.
			let l = try await fx.engine.createLease(LeaseRequest(name: "n"), viaNetwork: true)
			#expect(l.name == "n")
		}
	}
}

/// `blocking` for a call that cannot throw.
func blocking2<T: Sendable>(_ body: @escaping @Sendable () -> T) async -> T {
	(try? await blocking(body))!
}

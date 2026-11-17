import CryoAPI
import CryoClient
import CryoDeck
import CryoHTTP
import CryoServer
import FakeBay
import Foundation
import Testing

/// Polling, offline and online, status and doctor. Mostly on a manual clock with `pollOnce()`.
@Suite(.serialized) struct HealthTests {
	private func bays(_ fx: DeckFixture) async -> [Status.DeckBay] { await fx.engine.status().bays ?? [] }

	@Test func everyBayIsOnlineAfterStart() async throws {
		try await withManualDeck(bays: 3) { fx, _ in
			let all = await bays(fx)
			#expect(all.map(\.name) == ["mini-1", "mini-2", "mini-3"])
			#expect(all.allSatisfy { $0.online })
			#expect(all.map(\.url) == fx.entries.map(\.url))
		}
	}

	@Test func oneFailedPollIsNotEnoughButTwoTakeABayOffline() async throws {
		try await withManualDeck { fx, gates in
			gates[0].failStatus = true
			await fx.engine.pollOnce()
			#expect(await bays(fx).map(\.online) == [true, true])
			await fx.engine.pollOnce()
			#expect(await bays(fx).map(\.online) == [false, true])
		}
	}

	@Test func theThresholdIsASetting() async throws {
		var settings = DeckEngine.Settings()
		settings.failureThreshold = 3
		try await withManualDeck(settings: settings) { fx, gates in
			gates[0].failStatus = true
			await fx.engine.pollOnce()
			await fx.engine.pollOnce()
			#expect(await bays(fx).first?.online == true)
			await fx.engine.pollOnce()
			#expect(await bays(fx).first?.online == false)
		}
	}

	@Test func aSuccessInBetweenResetsTheCount() async throws {
		try await withManualDeck { fx, gates in
			gates[0].failStatus = true
			await fx.engine.pollOnce()
			gates[0].failStatus = false
			await fx.engine.pollOnce()
			gates[0].failStatus = true
			await fx.engine.pollOnce()
			#expect(await bays(fx).first?.online == true)
		}
	}

	@Test func anOfflineBayGetsNoNewLeasesAndComesBackOnTheNextSuccess() async throws {
		try await withManualDeck(bays: 2, capacity: 1) { fx, gates in
			gates[0].failStatus = true
			await fx.engine.pollOnce()
			await fx.engine.pollOnce()
			let l = try await fx.engineLease(LeaseRequest(waitS: 0))
			#expect(fx.bays[1].leases.count == 1 && fx.bays[0].leases.isEmpty)
			#expect(l.capsule == 0)
			try await fx.engine.release(l.id, saveCache: false)

			gates[0].failStatus = false
			await fx.engine.pollOnce()
			#expect(await bays(fx).map(\.online) == [true, true])
			// Round-robin goes on from after the last pick, so the first bay is next again.
			let again = try await fx.engineLease(LeaseRequest(waitS: 0))
			#expect(again.ssh.host == "cryo-D2")
			#expect(fx.bays[0].leases.count == 1)
		}
	}

	@Test func anOfflineBaysLeasesAreLostEvenWhenItComesBack() async throws {
		try await withManualDeck(bays: 2, capacity: 2) { fx, gates in
			_ = try await fx.lease()  // D1 on mini-1
			_ = try await fx.lease()  // D2 on mini-2
			gates[0].failStatus = true
			await fx.engine.pollOnce()
			await fx.engine.pollOnce()
			let f = try await fx.failure { _ = try $0.lease("D1") }
			#expect(f?.status == 410 && f?.code == APIError.leaseLost)
			let c = fx.client()
			let got1 = try await blocking { try c.listLeases() }.map(\.id)
			#expect(got1 == ["D2"])

			gates[0].failStatus = false
			await fx.engine.pollOnce()
			// The bay still holds its lease, but the deck dropped it: it stays lost.
			#expect(fx.bays[0].leases.count == 1)
			let still = try await fx.failure { _ = try $0.lease("D1") }
			#expect(still?.status == 410)
			let renew = try await fx.failure { _ = try $0.renew("D1") }
			#expect(renew?.status == 410)
			#expect(fx.bays[0].renews.isEmpty)
		}
	}

	@Test func anOfflineBayShowsNoCapsulesAndNothingIsRoutedToIt() async throws {
		try await withManualDeck(bays: 2) { fx, gates in
			gates[0].failStatus = true
			await fx.engine.pollOnce()
			await fx.engine.pollOnce()
			let s = await fx.engine.status()
			let b = try #require(s.bays?.first)
			#expect(!b.online && b.capsules.isEmpty && b.image == nil && b.version == nil)
			// Its capsules are not in the deck's numbering either.
			#expect(s.capsules.map(\.n) == [0, 1])
			let l = try await fx.engineLease()
			#expect(l.capsule == 0)
		}
	}

	@Test func theBackgroundPollTakesABayOffAndBack() async throws {
		try await withDeck(pollInterval: 0.05) { fx, gates in
			gates[1].failStatus = true
			#expect(await waitUntil { await bays(fx).map(\.online) == [true, false] })
			gates[1].failStatus = false
			#expect(await waitUntil { await bays(fx).map(\.online) == [true, true] })
		}
	}

	@Test func aBayThatNeverAnsweredIsOffline() async throws {
		let ghost = BayEntry(name: "ghost", url: "http://127.0.0.1:\(try deadPort())", token: "x")
		var settings = DeckEngine.Settings()
		settings.statusTimeout = 1
		let engine = DeckEngine(bays: [ghost], settings: settings)
		await engine.pollOnce()
		await engine.pollOnce()
		let s = await engine.status()
		#expect(s.bays?.first?.online == false)
		#expect(s.bay.doctor == Status.doctorFailing)
		#expect(s.bay.image == "-")
		let checks = await engine.doctor()
		#expect(checks.count == 1 && !checks[0].ok && checks[0].fix?.contains("cryo deck ls") == true)
	}

	// MARK: status

	@Test func statusMergesCapsulesAndKeepsEachBaysOwnNumbering() async throws {
		try await withManualDeck(bays: 2, capacity: 2) { fx, _ in
			_ = try await fx.lease()  // D1 mini-1 capsule 0
			_ = try await fx.lease()  // D2 mini-2 capsule 0
			await fx.engine.pollOnce()
			let c = fx.client()
			let s = try await blocking { try c.status() }
			#expect(s.bay.version == "test")
			#expect(s.bay.doctorOK)
			#expect(s.queue == 0)
			#expect(s.capsules.map(\.n) == [0, 1, 2, 3])
			#expect(s.capsules.map(\.state) == ["leased", "thawed", "leased", "thawed"])
			#expect(s.capsules.map(\.lease) == ["D1", nil, "D2", nil])
			let b = try #require(s.bays)
			#expect(b.map(\.name) == ["mini-1", "mini-2"])
			#expect(b.map(\.online) == [true, true])
			#expect(b.map(\.version) == ["fake", "fake"])
			#expect(b[0].capsules.map(\.n) == [0, 1])
			#expect(b[1].capsules.map(\.n) == [0, 1])
			#expect(b[1].capsules.map(\.lease) == ["D2", nil])
			#expect(b[0].url == fx.entries[0].url)
		}
	}

	@Test func aLeaseOnTheBayThatIsNotTheDecksShowsItsOwnID() async throws {
		try await withManualDeck(bays: 1, capacity: 2) { fx, _ in
			let direct = fx.bayClient(0)
			_ = try await blocking { try direct.createLease(LeaseRequest()) }
			await fx.engine.pollOnce()
			let s = await fx.engine.status()
			#expect(s.capsules.map(\.lease) == ["L1", nil])
		}
	}

	@Test func statusShowsTheQueueLength() async throws {
		try await withManualDeck(bays: 1, capacity: 1) { fx, _ in
			_ = try await fx.engineLease()
			let engine = fx.engine
			let tasks = (0..<2).map { _ in Task { try await engine.createLease(LeaseRequest(), viaNetwork: false) } }
			#expect(await waitUntil { await engine.status().queue == 2 })
			let c = fx.client()
			let got2 = try await blocking { try c.status() }.queue
			#expect(got2 == 2)
			for t in tasks { t.cancel() }
			for t in tasks { _ = try? await t.value }
			#expect(await waitUntil { await engine.status().queue == 0 })
		}
	}

	@Test func imageIsTheCommonOneOrMixedOrDash() async throws {
		try await withManualDeck(bays: 2) { fx, gates in
			#expect(await fx.engine.status().bay.image == "fake-image")
			gates[0].image = "image-a"
			await fx.engine.pollOnce()
			#expect(await fx.engine.status().bay.image == "mixed")
			gates[1].image = "image-a"
			await fx.engine.pollOnce()
			#expect(await fx.engine.status().bay.image == "image-a")
			// An offline bay does not count.
			gates[1].image = "image-b"
			gates[1].failStatus = true
			await fx.engine.pollOnce()
			await fx.engine.pollOnce()
			#expect(await fx.engine.status().bay.image == "image-a")
			gates[0].failStatus = true
			await fx.engine.pollOnce()
			await fx.engine.pollOnce()
			#expect(await fx.engine.status().bay.image == "-")
		}
	}

	@Test func doctorFieldIsOkWhileAnyBayIsOnline() async throws {
		try await withManualDeck(bays: 2) { fx, gates in
			gates[0].failStatus = true
			await fx.engine.pollOnce()
			await fx.engine.pollOnce()
			#expect(await fx.engine.status().bay.doctorOK)
			gates[1].failStatus = true
			await fx.engine.pollOnce()
			await fx.engine.pollOnce()
			#expect(await fx.engine.status().bay.doctor == Status.doctorFailing)
		}
	}

	@Test func aDeckWithoutBaysHasAnEmptyStatus() async throws {
		let s = await DeckEngine(bays: []).status()
		#expect(s.capsules.isEmpty && s.queue == 0)
		#expect(s.bays?.isEmpty == true)
		#expect(s.bay.image == "-" && s.bay.doctor == Status.doctorFailing)
	}

	// MARK: doctor

	@Test func doctorHasOneCheckPerBay() async throws {
		try await withManualDeck(bays: 2) { fx, gates in
			let c = fx.client()
			var checks = try await blocking { try c.doctor() }
			#expect(checks.map(\.check) == ["bay mini-1 online", "bay mini-2 online"])
			#expect(checks.allSatisfy { $0.ok })
			gates[1].failStatus = true
			await fx.engine.pollOnce()
			await fx.engine.pollOnce()
			checks = try await blocking { try c.doctor() }
			#expect(checks.map(\.ok) == [true, false])
			#expect(checks[1].fix?.contains("mini-1") == false)
			#expect(checks[1].fix?.contains(fx.entries[1].url) == true)
		}
	}

	@Test func doctorFailsWhenNoBayIsConfigured() async throws {
		let checks = await DeckEngine(bays: []).doctor()
		#expect(checks.count == 1)
		#expect(checks[0].ok == false)
		#expect(checks[0].check == "a bay is configured")
		#expect(checks[0].fix == "cryo deck add <name> <url> <token>")
	}

	// MARK: restart

	@Test func aRestartedDeckKeepsCountingAndForgetsOldLeases() async throws {
		let dir = try makeTempDir()
		defer { try? FileManager.default.removeItem(atPath: dir) }
		let counterFile = dir + "/deck-next-lease"
		try await withManualDeck(bays: 2, capacity: 2, counter: LeaseCounter(file: counterFile)) { fx, _ in
			let a = try await fx.lease()
			let b = try await fx.lease()
			#expect([a.id, b.id] == ["D1", "D2"])
			await fx.deck.stop()

			// A new deck on the same bays and the same counter file.
			let deck2 = Deck(
				bays: fx.entries, socketPath: dir + "/deck2.sock", token: "t2", version: "test",
				counter: LeaseCounter(file: counterFile))
			try await deck2.start(listen: ("127.0.0.1", 0))
			let c = CryoClient(target: CryoTarget(endpoint: .tcp(host: "127.0.0.1", port: deck2.tcpPort ?? 0), token: "t2"))
			do {
				// The old leases are still on their bays, but this deck does not know them.
				let f = await blocking2 { apiFailure { _ = try c.lease("D1") } }
				#expect(f?.status == 410 && f?.code == APIError.leaseLost)
				#expect(fx.bays[0].leases.count == 1 && fx.bays[1].leases.count == 1)
				let got3 = try await blocking { try c.listLeases() }.isEmpty
				#expect(got3)
				// They still take a capsule each, and show with the bay's own ids.
				let s = try await blocking { try c.status() }
				#expect(s.capsules.map(\.lease) == ["L1", nil, "L1", nil])
				// New leases go on from the counter file.
				let n = try await blocking { try c.createLease(LeaseRequest(waitS: 0)) }
				#expect(n.id == "D3")
				#expect(n.ssh.host == "cryo-D3")
			} catch {
				await deck2.stop()
				throw error
			}
			await deck2.stop()
		}
	}
}

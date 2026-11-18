import CryoAPI
import CryoClient
import CryoDeck
import CryoHTTP
import CryoServer
import FakeBay
import Foundation
import Testing

/// The deck's own FIFO queue. These run on a manual clock: a queued request moves only when the
/// test moves time (`pump`) or polls (`engine.pollOnce()`), so nothing depends on real waits.
@Suite(.serialized) struct QueueTests {
	private func queued(_ fx: DeckFixture, _ n: Int) async -> Bool {
		let engine = fx.engine
		return await waitUntil { await engine.status().queue == n }
	}

	/// Starts a request that waits in the queue; `done` is set when it ends.
	private func request(
		_ fx: DeckFixture, name: String, waitS: Int? = nil, done: Flag
	) -> Task<Lease, any Error> {
		let engine = fx.engine
		return Task {
			defer { done.set() }
			return try await engine.createLease(LeaseRequest(waitS: waitS, name: name), viaNetwork: false)
		}
	}

	@Test func aFullDeckQueuesAndServesInOrder() async throws {
		try await withManualDeck(bays: 1, capacity: 1) { fx, _ in
			let clock = try #require(fx.clock)
			let a = try await fx.engineLease()
			let (bDone, cDone) = (Flag(), Flag())
			let b = request(fx, name: "b", done: bDone)
			#expect(await queued(fx, 1))
			let c = request(fx, name: "c", done: cDone)
			#expect(await queued(fx, 2))

			try await fx.engine.release(a.id, saveCache: false)
			await fx.engine.pollOnce()
			#expect(await pump(clock) { bDone.isSet })
			let bl = try await b.value
			#expect(bl.id == "D2" && bl.name == "b")
			// c is still waiting: the only capsule is b's.
			_ = await pump(clock, seconds: 0.2) { false }
			#expect(!cDone.isSet)
			#expect(await fx.engine.status().queue == 1)

			try await fx.engine.release(bl.id, saveCache: false)
			await fx.engine.pollOnce()
			#expect(await pump(clock) { cDone.isSet })
			let cl = try await c.value
			#expect(cl.id == "D3" && cl.name == "c")
			#expect(await fx.engine.status().queue == 0)
		}
	}

	@Test func thereIsNoQueueAtTheBay() async throws {
		try await withManualDeck(bays: 1, capacity: 1) { fx, _ in
			_ = try await fx.engineLease()
			let done = Flag()
			let t = request(fx, name: "w", done: done)
			#expect(await queued(fx, 1))
			// The bay's own queue stays empty: the deck asked with wait_s 0.
			let c = fx.bayClient(0)
			let got1 = try await blocking { try c.status() }.queue
			#expect(got1 == 0)
			t.cancel()
			_ = try? await t.value
		}
	}

	@Test func aQueuedRequestGivesUpAtItsWait() async throws {
		try await withManualDeck(bays: 1, capacity: 1) { fx, _ in
			let clock = try #require(fx.clock)
			_ = try await fx.engineLease()
			let done = Flag()
			let engine = fx.engine
			let t = Task { () -> ServiceError? in
				let e = await serviceError { try await engine.createLease(LeaseRequest(waitS: 5), viaNetwork: false) }
				done.set()
				return e
			}
			#expect(await queued(fx, 1))
			// Not yet: 2 s of 5.
			clock.advance(2)
			_ = await pump(clock, step: 0.05, seconds: 0.1) { false }
			#expect(await engine.status().queue == 1)
			#expect(await pump(clock, step: 1) { done.isSet })
			let err = await t.value
			#expect(err?.status == 503 && err?.code == APIError.noCapacity)
			#expect(err?.message == "no free capsule on any bay")
			#expect(await engine.status().queue == 0)
		}
	}

	@Test func waitZeroDoesNotQueueAtAll() async throws {
		try await withManualDeck(bays: 1, capacity: 1) { fx, _ in
			_ = try await fx.engineLease()
			let err = await serviceError { try await fx.engineLease(LeaseRequest(waitS: 0)) }
			#expect(err?.code == APIError.noCapacity)
			#expect(await fx.engine.status().queue == 0)
		}
	}

	@Test func aRequestThatGivesUpFreesItsPlaceAndItsNumber() async throws {
		try await withManualDeck(bays: 1, capacity: 1) { fx, _ in
			let clock = try #require(fx.clock)
			let a = try await fx.engineLease()
			let gone = Flag()
			let leaving = request(fx, name: "leaving", done: gone)
			#expect(await queued(fx, 1))
			leaving.cancel()
			_ = try? await leaving.value
			#expect(await queued(fx, 0))

			let done = Flag()
			let waiting = request(fx, name: "waiting", done: done)
			#expect(await queued(fx, 1))
			try await fx.engine.release(a.id, saveCache: false)
			await fx.engine.pollOnce()
			#expect(await pump(clock) { done.isSet })
			// The one that left never got an id.
			let got2 = try await waiting.value.id
			#expect(got2 == "D2")
		}
	}

	@Test func aClientThatHangsUpWhileQueuedGivesUpItsPlace() async throws {
		try await withDeck(bays: 1, capacity: 1) { fx, _ in
			let a = try await fx.lease()
			let path = fx.socketPath
			let body = Array(#"{"wait_s":30}"#.utf8)
			let sock = try await blocking {
				let s = try Socket.connectUnix(path: path)
				var h = HTTPHeaders()
				h["Content-Type"] = "application/json"
				try s.writeAll(HTTPRequest(method: "POST", target: "/v1/leases", headers: h, body: body).serialized())
				return SendableSocket(s)
			}
			#expect(await waitUntil { await fx.engine.status().queue == 1 })
			sock.socket.close()
			#expect(await waitUntil { await fx.engine.status().queue == 0 })
			// The place is really gone: after a release the next request is served at once.
			let c = fx.client()
			try await blocking { try c.release(a.id) }
			await fx.engine.pollOnce()
			let next = try await fx.lease(LeaseRequest(waitS: 0))
			#expect(next.id == "D2")
			#expect(fx.bays[0].leases.count == 1)
		}
	}

	@Test func aQueuedRequestIsServedWhenAFreedCapsuleShowsUpInThePoll() async throws {
		// Real time, real poll loop: no pollOnce by hand.
		try await withDeck(bays: 1, capacity: 1) { fx, _ in
			let a = try await fx.lease()
			let engine = fx.engine
			let t = Task { try await engine.createLease(LeaseRequest(name: "q"), viaNetwork: false) }
			#expect(await queued(fx, 1))
			let c = fx.client()
			try await blocking { try c.release(a.id) }
			let l = try await t.value
			#expect(l.id == "D2" && l.name == "q")
		}
	}

	@Test func aQueuedRequestGoesToAnotherBayWhenOneGoesOffline() async throws {
		try await withManualDeck(bays: 2, capacity: 1) { fx, gates in
			let clock = try #require(fx.clock)
			let d1 = try await fx.engineLease()
			let d2 = try await fx.engineLease()
			let done = Flag()
			let t = request(fx, name: "q", done: done)
			#expect(await queued(fx, 1))

			// The second bay dies: its lease is gone, and it must not get the queued request.
			gates[1].failStatus = true
			gates[1].failCalls = true
			await fx.engine.pollOnce()
			await fx.engine.pollOnce()
			let lost = await serviceError { try await fx.engine.lease(d2.id) }
			#expect(lost?.status == 410)
			#expect(!done.isSet)

			try await fx.engine.release(d1.id, saveCache: false)
			await fx.engine.pollOnce()
			#expect(await pump(clock) { done.isSet })
			let l = try await t.value
			#expect(l.name == "q")
			#expect(fx.bays[0].leases.map(\.name) == ["q"])
			// The dead bay still holds the lease it had, and got nothing new.
			#expect(fx.bays[1].leases.count == 1)
		}
	}

	@Test func aQueuedRequestWaitsForABayToComeBack() async throws {
		try await withManualDeck(bays: 1, capacity: 1) { fx, gates in
			let clock = try #require(fx.clock)
			gates[0].failStatus = true
			await fx.engine.pollOnce()
			await fx.engine.pollOnce()
			#expect(await fx.engine.status().bays?.first?.online == false)
			let done = Flag()
			let t = request(fx, name: "q", done: done)
			#expect(await queued(fx, 1))
			gates[0].failStatus = false
			await fx.engine.pollOnce()
			#expect(await pump(clock) { done.isSet })
			let got3 = try await t.value.id
			#expect(got3 == "D1")
		}
	}

	@Test func whenNoBayIsOnlineTheErrorSaysSo() async throws {
		try await withManualDeck(bays: 2, capacity: 1) { fx, gates in
			gates[0].failStatus = true
			gates[1].failStatus = true
			await fx.engine.pollOnce()
			await fx.engine.pollOnce()
			let err = await serviceError { try await fx.engineLease(LeaseRequest(waitS: 0)) }
			#expect(err?.status == 503 && err?.code == APIError.noCapacity)
			#expect(err?.message == "no bay is online")
		}
	}

	@Test func aDeckWithoutBaysHasNothingToLeaseFrom() async throws {
		let engine = DeckEngine(bays: [])
		let err = await serviceError { try await engine.createLease(LeaseRequest(waitS: 0), viaNetwork: false) }
		#expect(err?.code == APIError.noCapacity)
		#expect(err?.message == "no bay is online")
	}

	@Test func manyQueuedRequestsAreAllServedOnce() async throws {
		try await withManualDeck(bays: 2, capacity: 1) { fx, _ in
			let clock = try #require(fx.clock)
			let first = [try await fx.engineLease(), try await fx.engineLease()]
			let flags = (0..<4).map { _ in Flag() }
			var tasks: [Task<Lease, any Error>] = []
			for (i, f) in flags.enumerated() {
				tasks.append(request(fx, name: "w\(i)", done: f))
				#expect(await queued(fx, i + 1))
			}
			// Free both capsules; two of the four get one, in order.
			for l in first { try await fx.engine.release(l.id, saveCache: false) }
			await fx.engine.pollOnce()
			#expect(await pump(clock) { flags[0].isSet && flags[1].isSet })
			_ = await pump(clock, seconds: 0.2) { false }
			#expect(!flags[2].isSet && !flags[3].isSet)
			let a = try await tasks[0].value
			let b = try await tasks[1].value
			#expect([a.name, b.name] == ["w0", "w1"])
			#expect(a.id != b.id)
			for t in tasks[2...] { t.cancel() }
			for t in tasks[2...] { _ = try? await t.value }
			#expect(await queued(fx, 0))
		}
	}
}

/// A socket moved between threads by a test (it is used by one at a time).
final class SendableSocket: @unchecked Sendable {
	let socket: Socket
	init(_ s: Socket) { socket = s }
}

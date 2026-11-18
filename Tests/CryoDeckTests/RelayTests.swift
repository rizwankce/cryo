import CryoAPI
import CryoClient
import CryoDeck
import CryoHTTP
import CryoServer
import FakeBay
import Foundation
import Testing

/// `connect` through the deck: the deck opens the owning bay's `connect` (which pipes to the fake
/// bay's echo server) and relays bytes both ways.
@Suite(.serialized) struct RelayTests {
	/// Opens `connect` for `id`, sends `payload`, reads the same number of bytes back and closes.
	private func echo(_ c: CryoClient, _ id: String, _ payload: [UInt8]) async throws -> [UInt8] {
		try await blocking {
			let s = try c.connect(id)
			defer { s.close() }
			try s.writeAll(payload)
			return try s.readExactly(payload.count)
		}
	}

	@Test func bytesGoBothWaysThroughTheDeck() async throws {
		try await withDeck { fx, _ in
			let l = try await fx.lease()
			let back = try await echo(fx.client(), l.id, Array("ping".utf8))
			#expect(back == Array("ping".utf8))
		}
	}

	@Test func itWorksOnTheSocketAsWell() async throws {
		try await withDeck(bays: 1) { fx, _ in
			let l = try await fx.lease(viaSocket: true)
			let back = try await echo(fx.client(viaSocket: true), l.id, Array("hello".utf8))
			#expect(back == Array("hello".utf8))
		}
	}

	@Test func aLargerPayloadArrivesWhole() async throws {
		try await withDeck(bays: 1) { fx, _ in
			let l = try await fx.lease()
			let payload = (0..<32_768).map { UInt8($0 % 251) }
			let got1 = try await echo(fx.client(), l.id, payload)
			#expect(got1 == payload)
		}
	}

	@Test func aStreamStaysOpenForSeveralRoundTrips() async throws {
		try await withDeck(bays: 1) { fx, _ in
			let l = try await fx.lease()
			let c = fx.client()
			let id = l.id
			let rounds = try await blocking {
				let s = try c.connect(id)
				defer { s.close() }
				var out: [[UInt8]] = []
				for i in 0..<5 {
					let msg = Array("round \(i)".utf8)
					try s.writeAll(msg)
					out.append(try s.readExactly(msg.count))
				}
				return out
			}
			#expect(rounds.map { String(decoding: $0, as: UTF8.self) } == (0..<5).map { "round \($0)" })
		}
	}

	@Test func leasesOnDifferentBaysRelayAtTheSameTime() async throws {
		try await withDeck { fx, _ in
			var ids: [String] = []
			for _ in 0..<4 { ids.append(try await fx.lease().id) }
			let c = fx.client()
			let results = try await withThrowingTaskGroup(of: (String, Bool).self) { group in
				for id in ids {
					group.addTask {
						let payload = Array("payload for \(id)".utf8)
						return (id, try await echo(c, id, payload) == payload)
					}
				}
				var all: [(String, Bool)] = []
				for try await r in group { all.append(r) }
				return all
			}
			#expect(results.count == 4 && results.allSatisfy { $0.1 })
		}
	}

	@Test func theRelayGoesToTheBayThatOwnsTheLease() async throws {
		try await withDeck { fx, _ in
			let a = try await fx.lease()  // mini-1
			let b = try await fx.lease()  // mini-2
			// Break the first bay's sshd: only its lease is affected.
			fx.bays[0].sshdPort = try deadPort()
			let bad = try await fx.failure { _ = try $0.connect(a.id) }
			#expect(bad?.status == 503 && bad?.code == APIError.capsuleUnreachable)
			let got2 = try await echo(fx.client(), b.id, Array("ok".utf8))
			#expect(got2 == Array("ok".utf8))
		}
	}

	@Test func aCapsuleThatDoesNotAnswerIsA503CapsuleUnreachable() async throws {
		try await withDeck(bays: 1) { fx, _ in
			let l = try await fx.lease()
			fx.bays[0].sshdPort = try deadPort()
			let f = try await fx.failure { _ = try $0.connect(l.id) }
			#expect(f?.status == 503 && f?.code == APIError.capsuleUnreachable)
			// The lease itself is fine.
			let c = fx.client()
			let got3 = try await blocking { try c.lease(l.id) }.id
			#expect(got3 == l.id)
		}
	}

	@Test func aBayThatCannotBeReachedForConnectIsA503CapsuleUnreachable() async throws {
		try await withManualDeck(bays: 1) { fx, gates in
			let l = try await fx.lease()
			gates[0].failConnect = true
			let f = try await fx.failure { _ = try $0.connect(l.id) }
			#expect(f?.status == 503 && f?.code == APIError.capsuleUnreachable)
			gates[0].failConnect = false
			let got4 = try await echo(fx.client(), l.id, Array("x".utf8))
			#expect(got4 == Array("x".utf8))
		}
	}

	@Test func aLeaseTheBayLostIsLeaseLostOnConnect() async throws {
		try await withManualDeck(bays: 1) { fx, _ in
			let l = try await fx.lease()
			fx.bays[0].loseLease("L1")
			let f = try await fx.failure { _ = try $0.connect(l.id) }
			#expect(f?.status == 410 && f?.code == APIError.leaseLost)
			// The deck forgot it.
			let c = fx.client()
			#expect(await waitUntil { (try? c.listLeases().isEmpty) == true })
		}
	}

	@Test func aLeaseOnAnOfflineBayIsLeaseLostOnConnect() async throws {
		try await withManualDeck(bays: 2) { fx, gates in
			let l = try await fx.lease()
			gates[0].failStatus = true
			await fx.engine.pollOnce()
			await fx.engine.pollOnce()
			let f = try await fx.failure { _ = try $0.connect(l.id) }
			#expect(f?.status == 410 && f?.code == APIError.leaseLost)
		}
	}

	@Test func closingTheClientEndLeavesTheDeckServingOthers() async throws {
		try await withDeck(bays: 1) { fx, _ in
			let l = try await fx.lease()
			let c = fx.client()
			let id = l.id
			// Open, send, and hang up without reading.
			try await blocking {
				let s = try c.connect(id)
				try s.writeAll(Array("abandoned".utf8))
				s.close()
			}
			let got5 = try await echo(c, id, Array("again".utf8))
			#expect(got5 == Array("again".utf8))
			let got6 = try await blocking { try c.status() }.capsules.count
			#expect(got6 == 2)
		}
	}

	@Test func theDeckStopsTheRelayWhenItIsStopped() async throws {
		try await withDeck(bays: 1) { fx, _ in
			let l = try await fx.lease()
			let c = fx.client()
			let id = l.id
			let deck = fx.deck
			let ended = try await blocking {
				let s = try c.connect(id)
				try s.writeAll(Array("a".utf8))
				_ = try s.readExactly(1)
				return SendableStream(s)
			}
			await deck.stop()
			// With the deck gone the stream ends: a read returns nothing or fails.
			let closed = try await blocking {
				let data = try? ended.stream.read()
				return data == nil || data!.isEmpty
			}
			#expect(closed)
		}
	}
}

/// A stream a test hands between threads (used by one at a time).
final class SendableStream: @unchecked Sendable {
	let stream: ByteStream
	init(_ s: ByteStream) { stream = s }
}

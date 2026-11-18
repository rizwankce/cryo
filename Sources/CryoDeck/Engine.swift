import CryoAPI
import CryoClient
import CryoHTTP
import CryoServer
import Foundation

/// Runs a blocking call on its own thread, so slow or dead bays never starve Swift's thread pool.
func offload<T: Sendable>(_ body: @escaping @Sendable () throws -> T) async throws -> T {
	try await withCheckedThrowingContinuation { cont in
		spawnThread { cont.resume(with: Result { try body() }) }
	}
}

/// The deck's `/v1` service (docs/spec/deck.md): hands leases out across bays, queues when all are
/// full, forwards the rest of a lease's life to the bay that owns it, polls bay health, and
/// relays `connect`. Lease ids are `D<n>`; the map to (bay, bay lease) lives in memory only.
public actor DeckEngine: BayService {
	public struct Settings: Sendable {
		/// Seconds between bay status polls.
		public var pollInterval: Double = 5
		/// While requests wait in the queue the poll runs this often (a freed capsule is seen sooner).
		public var queuePollInterval: Double = 1
		/// Consecutive failed polls before a bay is offline.
		public var failureThreshold: Int = 2
		/// Seconds a status poll waits for a bay.
		public var statusTimeout: Int = 3
		/// How often a queued request looks at the queue (seconds).
		public var queueTick: Double = 0.05
		/// `wait_s` when the client sends none (api.md).
		public var defaultWaitS: Int = 600

		public init() {}
	}

	private struct BayState {
		var entry: BayEntry
		var client: (any BayClient)?
		var online = false
		var failures = 0
		var status: Status?
		/// Set when the bay said `no_capacity` against its last status; cleared by the next poll.
		var full = false
		var thawed: Int { status?.capsules.filter { $0.state == "thawed" }.count ?? 0 }
	}

	private struct Mapping {
		var bay: String
		var leaseID: String
	}

	private var bays: [BayState]
	private var mappings: [String: Mapping] = [:]
	private var queue: [Int] = []
	private var nextTicket = 0
	private var rr = 0
	private var pollTask: Task<Void, Never>?

	private let settings: Settings
	private let version: String
	private let counter: LeaseCounter
	private let now: @Sendable () -> Double
	private let sleep: @Sendable (Double) async throws -> Void
	private let event: @Sendable (String) -> Void

	/// `now` and `sleep` are injected so tests control time; `event` receives one line per notable
	/// change (a bay going online or offline, a lease lost).
	public init(
		bays entries: [BayEntry], version: String = "dev", settings: Settings = Settings(),
		clientFactory: BayClientFactory = defaultBayClient, counter: LeaseCounter = LeaseCounter(),
		now: @escaping @Sendable () -> Double = { nowSeconds() },
		sleep: @escaping @Sendable (Double) async throws -> Void = { try await Task.sleep(for: .seconds($0)) },
		event: @escaping @Sendable (String) -> Void = { _ in }
	) {
		self.bays = entries.map { BayState(entry: $0, client: try? clientFactory($0)) }
		self.version = version
		self.settings = settings
		self.counter = counter
		self.now = now
		self.sleep = sleep
		self.event = event
	}

	// MARK: health

	/// Polls once now, then every `pollInterval`, until `stop()`.
	public func start() {
		guard pollTask == nil else { return }
		pollTask = Task { [weak self] in
			guard let self else { return }
			await self.pollLoop()
		}
	}

	public func stop() {
		pollTask?.cancel()
		pollTask = nil
	}

	private func pollLoop() async {
		while !Task.isCancelled {
			await pollOnce()
			let wait = queue.isEmpty ? settings.pollInterval : min(settings.pollInterval, settings.queuePollInterval)
			do { try await sleep(wait) } catch { return }
		}
	}

	/// `GET /v1/status` on every bay at once; `failureThreshold` failures in a row take a bay offline,
	/// the next success brings it back.
	public func pollOnce() async {
		let targets = bays.map { ($0.entry.name, $0.client) }
		let timeout = settings.statusTimeout
		let results = await withTaskGroup(of: (String, Result<Status, Error>).self) { group in
			for (name, client) in targets {
				group.addTask {
					guard let client else { return (name, .failure(DeckError("bad url"))) }
					do { return (name, .success(try await offload { try client.status(timeout: timeout) })) } catch { return (name, .failure(error)) }
				}
			}
			var all: [(String, Result<Status, Error>)] = []
			for await r in group { all.append(r) }
			return all
		}
		for (name, result) in results { apply(name, result) }
	}

	private func apply(_ name: String, _ result: Result<Status, Error>) {
		guard let i = bays.firstIndex(where: { $0.entry.name == name }) else { return }
		switch result {
		case .success(let s):
			if !bays[i].online { event("bay \(name) online") }
			bays[i].online = true
			bays[i].failures = 0
			bays[i].status = s
			bays[i].full = false
		case .failure(let e):
			bays[i].failures += 1
			if bays[i].online, bays[i].failures >= settings.failureThreshold {
				bays[i].online = false
				bays[i].status = nil
				event("bay \(name) offline: \(e)")
				dropMappings(of: name)
			}
		}
	}

	private func dropMappings(of bay: String) {
		for (id, m) in mappings where m.bay == bay {
			mappings.removeValue(forKey: id)
			event("lease \(id) lost: bay \(bay) is offline")
		}
	}

	// MARK: leases

	public func createLease(_ request: LeaseRequest, viaNetwork: Bool) async throws -> Lease {
		if request.folder != nil {
			throw ServiceError.badRequest("--folder doesn't work through a deck; use git clone or copy_in")
		}
		let wait = request.waitS ?? settings.defaultWaitS
		let deadline = now() + Double(wait)
		let ticket = nextTicket
		nextTicket += 1
		queue.append(ticket)
		defer { queue.removeAll { $0 == ticket } }
		var forward = request
		forward.waitS = 0
		forward.folder = nil
		while true {
			try Task.checkCancellation()
			if queue.first == ticket {
				for i in candidates() {
					guard let client = bays[i].client else { continue }
					let name = bays[i].entry.name
					let request = forward
					let lease: Lease
					do {
						lease = try await offload { try client.createLease(request) }
					} catch CryoClientError.api(let e, _) where e.code == APIError.noCapacity {
						bays[i].full = true
						continue
					} catch CryoClientError.transport {
						bays[i].full = true
						continue
					} catch {
						throw Self.convert(error)
					}
					if Task.isCancelled {
						// The client hung up while the bay thawed one: give it back.
						_ = try? await offload { try client.release(lease.id, saveCache: false) }
						throw CancellationError()
					}
					let id = "D\(counter.next())"
					mappings[id] = Mapping(bay: name, leaseID: lease.id)
					rr = (i + 1) % bays.count
					if let j = bays[i].status?.capsules.firstIndex(where: { $0.state == "thawed" }) {
						bays[i].status?.capsules[j].state = "leased"
						bays[i].status?.capsules[j].lease = lease.id
					}
					event("lease \(id) on \(name) (\(lease.id))")
					return DeckRewrite.lease(lease, from: lease.id, to: id, capsule: deckCapsule(lease.capsule, bay: i))
				}
			}
			let left = deadline - now()
			if left <= 0 {
				throw ServiceError.noCapacity(
					bays.contains { $0.online } ? "no free capsule on any bay" : "no bay is online")
			}
			try await sleep(min(settings.queueTick, left))
		}
	}

	/// Indexes of bays to try, round-robin from the one after the last pick.
	private func candidates() -> [Int] {
		guard !bays.isEmpty else { return [] }
		return (0..<bays.count).map { (rr + $0) % bays.count }.filter { bays[$0].online && !bays[$0].full && bays[$0].thawed > 0 }
	}

	/// Capsule `n` of bay `i` as numbered in `status()`, which lists every bay's capsules in turn.
	private func deckCapsule(_ n: Int, bay i: Int) -> Int {
		let offset = bays[..<i].reduce(0) { $0 + ($1.online ? ($1.status?.capsules.count ?? 0) : 0) }
		return DeckRewrite.capsuleNumber(n, offset: offset, bayCapsules: bays[i].status?.capsules.map(\.n) ?? [])
	}

	public func lease(_ id: String) async throws -> Lease {
		let (lease, m) = try await forward(id) { client, bayID in try client.lease(bayID) }
		return rewritten(lease, id: id, mapping: m)
	}

	public func renew(_ id: String) async throws -> RenewResponse {
		try await forward(id) { client, bayID in try client.renew(bayID) }.0
	}

	public func release(_ id: String, saveCache: Bool) async throws {
		_ = try await forward(id) { client, bayID in try client.release(bayID, saveCache: saveCache) }
		mappings.removeValue(forKey: id)
		event("lease \(id) released")
	}

	private func rewritten(_ lease: Lease, id: String, mapping m: Mapping) -> Lease {
		let capsule = bays.firstIndex { $0.entry.name == m.bay }.map { deckCapsule(lease.capsule, bay: $0) }
		return DeckRewrite.lease(lease, from: m.leaseID, to: id, capsule: capsule)
	}

	/// Runs `op` against the bay that owns `id`. A lease the deck doesn't know, a bay that is
	/// offline or gone, and a bay that says the lease is gone all end as `410 lease_lost`.
	private func forward<T: Sendable>(
		_ id: String, _ op: @escaping @Sendable (any BayClient, String) throws -> T
	) async throws -> (T, Mapping) {
		guard let m = mappings[id] else { throw ServiceError.leaseLost(id, "the deck does not know it") }
		guard let i = bays.firstIndex(where: { $0.entry.name == m.bay }), bays[i].online, let client = bays[i].client else {
			lose(id, "bay \(m.bay) is offline")
			throw ServiceError.leaseLost(id, "bay \(m.bay) is offline")
		}
		do {
			return (try await offload { try op(client, m.leaseID) }, m)
		} catch {
			if Self.isGone(error) {
				lose(id, "the bay lost it")
				throw ServiceError.leaseLost(id, "the bay lost it")
			}
			throw Self.convert(error)
		}
	}

	private func lose(_ id: String, _ why: String) {
		if mappings.removeValue(forKey: id) != nil { event("lease \(id) lost: \(why)") }
	}

	public func leases() async -> [Lease] {
		var byBay: [String: [String: String]] = [:]  // bay -> bay lease id -> D-id
		for (id, m) in mappings { byBay[m.bay, default: [:]][m.leaseID] = id }
		let targets = bays.filter { $0.online && byBay[$0.entry.name] != nil }.compactMap { b in b.client.map { (b.entry.name, $0) } }
		let listed = await withTaskGroup(of: (String, [Lease]?).self) { group in
			for (name, client) in targets {
				group.addTask { (name, try? await offload { try client.listLeases() }) }
			}
			var all: [(String, [Lease]?)] = []
			for await r in group { all.append(r) }
			return all
		}
		var out: [(Int, Lease)] = []
		for (name, list) in listed {
			// A bay that could not answer says nothing about its leases.
			guard let list, let ids = byBay[name] else { continue }
			for (bayID, did) in ids {
				guard let l = list.first(where: { $0.id == bayID }), let m = mappings[did] else {
					lose(did, "no longer on bay \(name)")
					continue
				}
				out.append((Int(did.dropFirst()) ?? 0, rewritten(l, id: did, mapping: m)))
			}
		}
		return out.sorted { $0.0 < $1.0 }.map(\.1)
	}

	// MARK: status

	public func status() async -> Status {
		var capsules: [Status.Capsule] = []
		var reverse: [String: String] = [:]
		for (id, m) in mappings { reverse["\(m.bay)/\(m.leaseID)"] = id }
		var deckBays: [Status.DeckBay] = []
		for b in bays {
			let own = (b.status?.capsules ?? []).map { c in
				Status.Capsule(n: c.n, state: c.state, lease: c.lease.map { reverse["\(b.entry.name)/\($0)"] ?? $0 })
			}
			deckBays.append(
				Status.DeckBay(
					name: b.entry.name, url: b.entry.url, online: b.online, capsules: own, image: b.status?.bay.image, version: b.status?.bay.version))
			for c in own { capsules.append(Status.Capsule(n: capsules.count, state: c.state, lease: c.lease)) }
		}
		let images = Set(bays.filter(\.online).compactMap { $0.status?.bay.image })
		let anyOnline = bays.contains { $0.online }
		return Status(
			bay: .init(
				version: version, image: images.count == 1 ? images.first! : (images.isEmpty ? "-" : "mixed"),
				doctor: anyOnline ? Status.doctorOK : Status.doctorFailing),
			capsules: capsules, queue: queue.count, bays: deckBays)
	}

	public func doctor() async -> [DoctorCheck] {
		if bays.isEmpty { return [DoctorCheck(check: "a bay is configured", ok: false, fix: "cryo deck add <name> <url> <token>")] }
		return bays.map { b in
			DoctorCheck(
				check: "bay \(b.entry.name) online", ok: b.online,
				fix: b.online ? nil : "check that `cryo bay` runs at \(b.entry.url) and its token matches (cryo deck ls)")
		}
	}

	// MARK: connect

	public func connectTarget(_ id: String) async throws -> (host: String, port: Int) {
		throw ServiceError.internal("a deck relays connect streams to the bay")
	}

	public func connectionOpened(_ id: String) async {}
	public func connectionClosed(_ id: String) async {}

	/// Relay to the owning bay's own `connect`: the server copies bytes both ways until either
	/// side closes (or the lease ends: it keeps asking `lease(id)`).
	public func connectRoute(_ id: String) async throws -> ConnectRoute {
		guard let m = mappings[id] else { throw ServiceError.leaseLost(id, "the deck does not know it") }
		guard let i = bays.firstIndex(where: { $0.entry.name == m.bay }), bays[i].online, let client = bays[i].client else {
			lose(id, "bay \(m.bay) is offline")
			throw ServiceError.leaseLost(id, "bay \(m.bay) is offline")
		}
		return .upstream { [weak self] in
			do {
				return try client.connect(m.leaseID)
			} catch {
				if Self.isGone(error) {
					Task { await self?.lose(id, "the bay lost it") }
					throw ServiceError.leaseLost(id, "the bay lost it")
				}
				throw Self.convert(error, connect: true)
			}
		}
	}

	// MARK: errors

	/// The bay says the lease is not there (anymore).
	static func isGone(_ error: Error) -> Bool {
		if case CryoClientError.api(let e, let status) = error {
			return status == 410 || e.code == APIError.leaseLost || status == 404 || e.code == APIError.notFound
		}
		return false
	}

	static func convert(_ error: Error, connect: Bool = false) -> Error {
		switch error {
		case let e as ServiceError: return e
		case is CancellationError: return error
		case CryoClientError.api(let e, let status): return ServiceError(status, e.code, e.message)
		case CryoClientError.transport(_, let message):
			return ServiceError(503, connect ? APIError.capsuleUnreachable : "bay_unreachable", "bay unreachable: \(message)")
		case CryoClientError.upgradeRequired(let m): return ServiceError(502, "bay_incompatible", m)
		case CryoClientError.badResponse(let m): return ServiceError(502, "bay_error", m)
		default: return ServiceError.internal("\(error)")
		}
	}
}

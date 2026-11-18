#if canImport(FoundationEssentials)
	import FoundationEssentials
#else
	import Foundation
#endif

/// Bay API v1 wire types (docs/spec/api.md). JSON keys are snake_case.

public let apiVersionHeader = "Cryo-Api-Version"
public let apiVersion = 1

/// A bay that exits for a restart (taken subnets) leaves its alert in this file next to its
/// socket, and removes it once a bay is ready. Between restarts no bay answers, so `cryo status`
/// reads it there instead.
public enum RestartNote {
	public static let fileName = "bay-restarting"
	/// Older than this, the note is from a bay that stopped restarting (unloaded, or a crash).
	public static let maxAgeS: Double = 300

	/// `<unix seconds>\n<alert>\n`: the time is in the file so readers don't need its mtime.
	public static func text(alert: String, now: Double) -> String { "\(Int(now))\n\(alert)\n" }

	/// The alert, or nil if the note is malformed, empty or older than `maxAgeS`.
	public static func parse(_ text: String, now: Double) -> String? {
		let lines = text.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false)
		guard lines.count == 2, let t = Double(lines[0]), now - t < maxAgeS else { return nil }
		let alert = lines[1].split(separator: "\n").joined(separator: " ")
		return alert.isEmpty ? nil : alert
	}
}

public struct SSHInfo: Codable, Sendable, Equatable {
	public var user: String
	public var host: String
	public var key: String
	public var config: String
	/// The guest's public host key (`ssh-ed25519 AAAA…`), made at refill. Clients pin it in
	/// `~/.cryo/known_hosts/<id>`, which `config` names as the lease's only known_hosts file.
	public var hostKey: String?

	public init(user: String, host: String, key: String, config: String, hostKey: String? = nil) {
		self.user = user
		self.host = host
		self.key = key
		self.config = config
		self.hostKey = hostKey
	}

	enum CodingKeys: String, CodingKey {
		case user, host, key, config
		case hostKey = "host_key"
	}
}

public struct Lease: Codable, Sendable, Equatable {
	public var id: String
	public var name: String?
	public var capsule: Int
	public var state: String
	public var createdAt: Date
	public var renewBy: Date
	public var expiresAt: Date
	public var cache: String?
	/// Idle timeout in seconds the bay applied (request's `idle_s`, default 3600, capped at 86400).
	public var idleS: Int?
	public var ssh: SSHInfo

	public init(
		id: String, name: String? = nil, capsule: Int, state: String, createdAt: Date,
		renewBy: Date, expiresAt: Date, cache: String? = nil, idleS: Int? = nil, ssh: SSHInfo
	) {
		self.id = id
		self.name = name
		self.capsule = capsule
		self.state = state
		self.createdAt = createdAt
		self.renewBy = renewBy
		self.expiresAt = expiresAt
		self.cache = cache
		self.idleS = idleS
		self.ssh = ssh
	}

	enum CodingKeys: String, CodingKey {
		case id, name, capsule, state
		case createdAt = "created_at"
		case renewBy = "renew_by"
		case expiresAt = "expires_at"
		case cache
		case idleS = "idle_s"
		case ssh
	}
}

public struct LeaseRequest: Codable, Sendable, Equatable {
	public var folder: String?
	public var cache: String?
	public var waitS: Int?
	public var name: String?
	/// Per-lease idle timeout in seconds: default 3600, the bay caps it at 86400 (MCP sends 300).
	public var idleS: Int?

	public init(folder: String? = nil, cache: String? = nil, waitS: Int? = nil, name: String? = nil, idleS: Int? = nil) {
		self.folder = folder
		self.cache = cache
		self.waitS = waitS
		self.name = name
		self.idleS = idleS
	}

	enum CodingKeys: String, CodingKey {
		case folder, cache
		case waitS = "wait_s"
		case name
		case idleS = "idle_s"
	}
}

public struct RenewResponse: Codable, Sendable, Equatable {
	public var renewBy: Date

	public init(renewBy: Date) { self.renewBy = renewBy }

	enum CodingKeys: String, CodingKey { case renewBy = "renew_by" }
}

/// `bay.doctor` is a summary string (full results come from /v1/doctor); `capsules[].lease` is the
/// lease id or null; `queue` is the number of waiting requests.
public struct Status: Codable, Sendable, Equatable {
	public struct Bay: Codable, Sendable, Equatable {
		public var version: String
		public var image: String
		/// `"ok"` or `"failing"`; clients treat any other value (e.g. a later `"warn"`) as not ok.
		public var doctor: String
		public var doctorOK: Bool { doctor == Status.doctorOK }
		/// The failing host checks that keep the bay from thawing (setup.md); nil once it may thaw.
		/// Added within v1: older bays omit it.
		public var blockedBy: [String]?
		/// Something only a person can fix, with the command to run (e.g. taken vmnet subnets).
		/// Added within v1: older bays omit it.
		public var alert: String?

		public init(version: String, image: String, doctor: String, blockedBy: [String]? = nil, alert: String? = nil) {
			self.version = version
			self.image = image
			self.doctor = doctor
			self.blockedBy = blockedBy
			self.alert = alert
		}

		enum CodingKeys: String, CodingKey {
			case version, image, doctor, alert
			case blockedBy = "blocked_by"
		}
	}

	public struct Capsule: Codable, Sendable, Equatable {
		public var n: Int
		public var state: String
		public var lease: String?

		public init(n: Int, state: String, lease: String? = nil) {
			self.n = n
			self.state = state
			self.lease = lease
		}
	}

	/// Host health and counters since the bay started (api.md "Health"). Counters reset when the
	/// bay restarts.
	public struct Health: Codable, Sendable, Equatable {
		/// Seconds since the bay started; host seconds since boot (watch hosts past ~50 days).
		public var uptimeS: Int
		public var hostUptimeS: Int
		/// Free space on the volume holding `~/.cryo`; nil when the bay can't read it.
		public var diskFreeBytes: Int64?
		/// `nominal`, `fair`, `serious` or `critical` (ProcessInfo.thermalState).
		public var thermal: String
		/// Leases handed out, leases that failed to start, leases ended by idle timeout or maximum length.
		public var leasesServed: Int
		public var leasesFailed: Int
		public var leasesExpired: Int
		/// Capsule refills that succeeded and that failed (each attempt counts).
		public var refills: Int
		public var refillsFailed: Int
		/// Duration of the most recent lease start and refill; nil until one happened.
		public var lastLeaseMS: Int?
		public var lastRefillMS: Int?

		public init(
			uptimeS: Int, hostUptimeS: Int, diskFreeBytes: Int64? = nil, thermal: String,
			leasesServed: Int = 0, leasesFailed: Int = 0, leasesExpired: Int = 0, refills: Int = 0, refillsFailed: Int = 0,
			lastLeaseMS: Int? = nil, lastRefillMS: Int? = nil
		) {
			self.uptimeS = uptimeS
			self.hostUptimeS = hostUptimeS
			self.diskFreeBytes = diskFreeBytes
			self.thermal = thermal
			self.leasesServed = leasesServed
			self.leasesFailed = leasesFailed
			self.leasesExpired = leasesExpired
			self.refills = refills
			self.refillsFailed = refillsFailed
			self.lastLeaseMS = lastLeaseMS
			self.lastRefillMS = lastRefillMS
		}

		enum CodingKeys: String, CodingKey {
			case uptimeS = "uptime_s"
			case hostUptimeS = "host_uptime_s"
			case diskFreeBytes = "disk_free_bytes"
			case thermal
			case leasesServed = "leases_served"
			case leasesFailed = "leases_failed"
			case leasesExpired = "leases_expired"
			case refills
			case refillsFailed = "refills_failed"
			case lastLeaseMS = "last_lease_ms"
			case lastRefillMS = "last_refill_ms"
		}
	}

	/// A bay as a deck sees it (`cryo deck`): its own capsule numbers, `image` and `version` nil
	/// while it is offline.
	public struct DeckBay: Codable, Sendable, Equatable {
		public var name: String
		public var url: String
		public var online: Bool
		public var capsules: [Capsule]
		public var image: String?
		public var version: String?

		public init(name: String, url: String, online: Bool, capsules: [Capsule] = [], image: String? = nil, version: String? = nil) {
			self.name = name
			self.url = url
			self.online = online
			self.capsules = capsules
			self.image = image
			self.version = version
		}
	}

	public static let doctorOK = "ok"
	public static let doctorFailing = "failing"

	public var bay: Bay
	public var capsules: [Capsule]
	public var queue: Int
	/// Added within v1: older bays omit it, so clients must handle nil.
	public var health: Health?
	/// Only a deck sends it: one entry per bay behind it. Added within v1: clients that don't
	/// know it ignore it, and a bay never sets it.
	public var bays: [DeckBay]?

	public init(bay: Bay, capsules: [Capsule], queue: Int, health: Health? = nil, bays: [DeckBay]? = nil) {
		self.bay = bay
		self.capsules = capsules
		self.queue = queue
		self.health = health
		self.bays = bays
	}
}

public struct DoctorCheck: Codable, Sendable, Equatable {
	public var check: String
	public var ok: Bool
	public var fix: String?

	public init(check: String, ok: Bool, fix: String? = nil) {
		self.check = check
		self.ok = ok
		self.fix = fix
	}
}

/// Error envelope: `{"error": {"code": "…", "message": "…"}}`.
public struct APIError: Codable, Error, Sendable, Equatable {
	public static let noCapacity = "no_capacity"
	public static let notFound = "not_found"
	public static let unauthorized = "unauthorized"
	public static let upgradeRequired = "upgrade_required"
	public static let badRequest = "bad_request"
	public static let leaseLost = "lease_lost"
	/// `connect`: the capsule's sshd didn't answer (503).
	public static let capsuleUnreachable = "capsule_unreachable"

	public var code: String
	public var message: String

	public init(code: String, message: String) {
		self.code = code
		self.message = message
	}

	enum OuterKeys: String, CodingKey { case error }
	enum InnerKeys: String, CodingKey { case code, message }

	public init(from decoder: Decoder) throws {
		let outer = try decoder.container(keyedBy: OuterKeys.self)
		let inner = try outer.nestedContainer(keyedBy: InnerKeys.self, forKey: .error)
		code = try inner.decode(String.self, forKey: .code)
		message = try inner.decode(String.self, forKey: .message)
	}

	public func encode(to encoder: Encoder) throws {
		var outer = encoder.container(keyedBy: OuterKeys.self)
		var inner = outer.nestedContainer(keyedBy: InnerKeys.self, forKey: .error)
		try inner.encode(code, forKey: .code)
		try inner.encode(message, forKey: .message)
	}
}

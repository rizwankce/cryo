import CryoAPI
import Foundation

/// What the bay counts for `/v1/status` `health` (api.md "Health"). Pure; the bay records events
/// and `health(...)` adds the host readings.
struct HealthCounters: Equatable {
	var leasesServed = 0
	var leasesFailed = 0
	var leasesExpired = 0
	var refills = 0
	var refillsFailed = 0
	var lastLeaseMS: Int?
	var lastRefillMS: Int?

	mutating func leaseStarted(ms: Int) {
		leasesServed += 1
		lastLeaseMS = ms
	}

	mutating func leaseFailed() { leasesFailed += 1 }

	/// Only the bay's own limits count as expired; client releases and shutdowns don't.
	mutating func leaseEnded(_ reason: EndReason) {
		if reason == .idle || reason == .maxLength { leasesExpired += 1 }
	}

	mutating func refilled(ms: Int) {
		refills += 1
		lastRefillMS = ms
	}

	mutating func refillFailed() { refillsFailed += 1 }

	func health(uptimeS: Int, hostUptimeS: Int, diskFreeBytes: Int64?, thermal: String) -> Status.Health {
		Status.Health(
			uptimeS: uptimeS, hostUptimeS: hostUptimeS, diskFreeBytes: diskFreeBytes, thermal: thermal,
			leasesServed: leasesServed, leasesFailed: leasesFailed, leasesExpired: leasesExpired,
			refills: refills, refillsFailed: refillsFailed, lastLeaseMS: lastLeaseMS, lastRefillMS: lastRefillMS)
	}
}

extension Host {
	static var uptimeS: Int { Int(ProcessInfo.processInfo.systemUptime) }

	/// Free space for important use on the volume holding `url` (what macOS will make room for).
	static func diskFreeBytes(_ url: URL) -> Int64? {
		try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]).volumeAvailableCapacityForImportantUsage
	}

	static var thermal: String {
		switch ProcessInfo.processInfo.thermalState {
		case .nominal: return "nominal"
		case .fair: return "fair"
		case .serious: return "serious"
		case .critical: return "critical"
		@unknown default: return "unknown"
		}
	}
}

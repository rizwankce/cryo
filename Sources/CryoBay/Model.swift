import Foundation

/// `images/<digest>/image.json`.
public struct ImageInfo: Codable, Sendable, Equatable {
	/// Content identity of the image (directory name).
	public var digest: String
	/// Human tag, also the CI label, e.g. `xcode-27.2`.
	public var tag: String
	/// Guest macOS, e.g. `27.2 (26B123)`.
	public var macOS: String
	/// vCPUs and memory every capsule of this image gets (docs/spec/capsule.md "Shape").
	public var cpus: Int
	public var memoryGB: Int
	public var createdAt: Date
	/// Xcode in the guest, e.g. `27.2 (27B52)`; nil for a plain macOS image (and images made before `cryo image build` recorded it).
	public var xcode: String?

	public init(digest: String, tag: String, macOS: String, cpus: Int, memoryGB: Int, createdAt: Date, xcode: String? = nil) {
		self.digest = digest
		self.tag = tag
		self.macOS = macOS
		self.cpus = cpus
		self.memoryGB = memoryGB
		self.createdAt = createdAt
		self.xcode = xcode
	}

	enum CodingKeys: String, CodingKey {
		case digest, tag
		case macOS = "macos"
		case cpus
		case memoryGB = "memory_gb"
		case createdAt = "created_at"
		case xcode
	}
}

/// A capsule's own network: vmnet `10.77.<subnet>.0/24`, guest pinned at `.2`, no port forward.
/// Kept per capsule because the guest's IP is inside the saved state: a capsule frozen on subnet 2
/// must always restore on subnet 2, whatever its capsule number.
public struct CapsuleNetwork: Codable, Sendable, Equatable {
	public var subnet: Int

	public init(subnet: Int) { self.subnet = subnet }

	/// vmnet takes the host (gateway) address.
	public var gateway: String { "10.77.\(subnet).1" }
	public var guestIP: String { "10.77.\(subnet).2" }

	/// Pins the guest's own address (set at freeze, kept in the capsule's disk layer): vmnet's DHCP
	/// reservation didn't always reach bootpd, which then gave the guest .3 or stalled the first
	/// SSH after a restore by ~4 s. DNS stays vmnet's proxy on the gateway.
	public var staticIPCommand: String {
		"sudo -n networksetup -setmanual Ethernet \(guestIP) 255.255.255.0 \(gateway) && sudo -n networksetup -setdnsservers Ethernet \(gateway)"
	}
}

/// `capsules/<N>/manifest.json`: what the saved state was frozen with. Any difference at restore
/// time means the state can't be trusted: cold boot instead and refreeze.
public struct CapsuleManifest: Codable, Sendable, Equatable {
	public var image: String
	public var cpus: Int
	public var memoryGB: Int
	public var mac: String
	public var network: CapsuleNetwork
	/// Devices that are part of the saved configuration and must match on every restore.
	public var vsock: Bool
	/// Virtiofs placeholder share + XHCI controller, so leases can get a folder and a USB disk.
	public var inputs: Bool
	/// `model | chip | macOS build` of the host it was frozen on.
	public var host: String
	/// `size@mtime` stamps of the files the state depends on.
	public var files: [String: String]
	public var frozenAt: Date
	/// Cold boot to SSH during the freeze, for the record.
	public var coldBootMS: Int?
	/// Warm-up build platforms baked in at freeze, so a background refreeze bakes the same;
	/// nil in manifests from before this was recorded (RefreezePlan.warmUp then decides by image).
	public var warmUp: [String]?

	public init(
		image: String, cpus: Int, memoryGB: Int, mac: String, network: CapsuleNetwork, vsock: Bool, inputs: Bool,
		host: String, files: [String: String], frozenAt: Date, coldBootMS: Int? = nil, warmUp: [String]? = nil
	) {
		self.image = image
		self.cpus = cpus
		self.memoryGB = memoryGB
		self.mac = mac
		self.network = network
		self.vsock = vsock
		self.inputs = inputs
		self.host = host
		self.files = files
		self.frozenAt = frozenAt
		self.coldBootMS = coldBootMS
		self.warmUp = warmUp
	}

	enum CodingKeys: String, CodingKey {
		case image, cpus
		case memoryGB = "memory_gb"
		case mac, network, vsock, inputs, host, files
		case frozenAt = "frozen_at"
		case coldBootMS = "cold_boot_ms"
		case warmUp = "warm_up"
	}
}

public enum BayJSON {
	public static func encoder() -> JSONEncoder {
		let e = JSONEncoder()
		e.outputFormatting = [.prettyPrinted, .sortedKeys]
		e.dateEncodingStrategy = .iso8601
		return e
	}

	public static func decoder() -> JSONDecoder {
		let d = JSONDecoder()
		d.dateDecodingStrategy = .iso8601
		return d
	}

	public static func write<T: Encodable>(_ value: T, to url: URL) throws {
		try encoder().encode(value).write(to: url, options: .atomic)
	}

	public static func read<T: Decodable>(_ type: T.Type, from url: URL) throws -> T {
		try decoder().decode(type, from: Data(contentsOf: url))
	}
}

public struct BayError: Error, CustomStringConvertible, Sendable {
	public let description: String
	public init(_ description: String) { self.description = description }
}

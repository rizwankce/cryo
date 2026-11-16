import Darwin
import DiskImageKit
import Foundation
import Virtualization
import vmnet

/// Everything needed to build one capsule's VM. The device set is the one the capsule was frozen
/// with (vmnet, plus vsock and inputs as its manifest says): a saved state only restores onto the
/// same devices. New freezes have no vsock device; capsules frozen with one keep it.
public struct VMSpec: Sendable {
	public var hardwareModel: URL
	public var machineID: URL
	public var mac: String
	/// Aux storage this VM boots from: a per-lease clone, never the capsule's own.
	public var aux: URL
	public var cpus: Int
	public var memoryGB: Int
	public var subnet: Int
	public var vsock: Bool
	public var inputs: Bool
	/// Empty directory for the placeholder virtiofs share.
	public var emptyShare: URL

	public init(
		hardwareModel: URL, machineID: URL, mac: String, aux: URL, cpus: Int, memoryGB: Int, subnet: Int,
		vsock: Bool, inputs: Bool, emptyShare: URL
	) {
		self.hardwareModel = hardwareModel
		self.machineID = machineID
		self.mac = mac
		self.aux = aux
		self.cpus = cpus
		self.memoryGB = memoryGB
		self.subnet = subnet
		self.vsock = vsock
		self.inputs = inputs
		self.emptyShare = emptyShare
	}

	/// The spec a capsule restores with: everything comes from its manifest and identity files.
	public init(image: ImageFiles, capsule: CapsuleFiles, manifest: CapsuleManifest, aux: URL, emptyShare: URL) {
		self.init(
			hardwareModel: image.hardwareModel, machineID: capsule.machineID, mac: manifest.mac, aux: aux,
			cpus: manifest.cpus, memoryGB: manifest.memoryGB, subnet: manifest.network.subnet,
			vsock: manifest.vsock, inputs: manifest.inputs, emptyShare: emptyShare)
	}
}

/// One capsule's `VZVirtualMachine`. Virtualization.framework objects belong to the main actor.
@MainActor
public final class CapsuleVM {
	public let vm: VZVirtualMachine

	init(_ vm: VZVirtualMachine) {
		self.vm = vm
		// Every refill makes a VM; drop the ones already gone so the list doesn't grow with the bay's uptime.
		Self.live.removeAll { $0.vm == nil }
		Self.live.append(WeakVM(vm))
	}

	public var state: VZVirtualMachine.State { vm.state }

	// MARK: Disks

	/// Host caching for lease disks; automatic measured fastest.
	static let leaseCaching: VZDiskImageCachingMode = .automatic

	/// Freeze: a new thin layer over the read-only base. Default synchronization, since this
	/// layer is kept.
	public static func freezeDisk(image: ImageFiles, capsule: CapsuleFiles) throws -> VZStorageDeviceAttachment {
		let base = try DiskImage(opening: OpenConfiguration(url: image.base, mode: .readOnly))
		let stacked = try base.appending(ASIFCreationConfiguration.layer(url: capsule.freezeLayer, type: .overlay))
		return try VZDiskImageStorageDeviceAttachment(diskImage: stacked)
	}

	/// Lease: base (ro) → the capsule's freeze layer (ro) → a fresh overlay (rw, never fsynced: the
	/// VM is thrown away).
	public static func leaseDisk(image: ImageFiles, capsule: CapsuleFiles, overlay: URL) throws -> VZStorageDeviceAttachment {
		let base = try DiskImage(opening: OpenConfiguration(url: image.base, mode: .readOnly))
		let frozen = try DiskImage(opening: OpenConfiguration(url: capsule.freezeLayer, mode: .readOnly))
		let stacked = try base.appending(frozen).appending(ASIFCreationConfiguration.layer(url: overlay, type: .overlay))
		return try VZDiskImageStorageDeviceAttachment(diskImage: stacked, cachingMode: leaseCaching, synchronizationMode: .none)
	}

	// MARK: Build

	public static func make(_ spec: VMSpec, disk: VZStorageDeviceAttachment) throws -> CapsuleVM {
		guard let hw = VZMacHardwareModel(dataRepresentation: try Data(contentsOf: spec.hardwareModel)) else {
			throw BayError("bad hardware model at \(spec.hardwareModel.path)")
		}
		guard let id = VZMacMachineIdentifier(dataRepresentation: try Data(contentsOf: spec.machineID)) else {
			throw BayError("bad machine id at \(spec.machineID.path)")
		}
		guard let mac = VZMACAddress(string: spec.mac) else { throw BayError("bad MAC '\(spec.mac)'") }

		let platform = VZMacPlatformConfiguration()
		platform.hardwareModel = hw
		platform.machineIdentifier = id
		platform.auxiliaryStorage = VZMacAuxiliaryStorage(url: spec.aux)

		let c = VZVirtualMachineConfiguration()
		c.platform = platform
		c.bootLoader = VZMacOSBootLoader()
		c.cpuCount = spec.cpus
		c.memorySize = UInt64(spec.memoryGB) << 30

		let gfx = VZMacGraphicsDeviceConfiguration()
		gfx.displays = [VZMacGraphicsDisplayConfiguration(widthInPixels: 1920, heightInPixels: 1080, pixelsPerInch: 80)]
		c.graphicsDevices = [gfx]
		c.storageDevices = [VZVirtioBlockDeviceConfiguration(attachment: disk)]

		let net = VZVirtioNetworkDeviceConfiguration()
		net.attachment = VZVmnetNetworkDeviceAttachment(network: try vmnetNetwork(subnet: spec.subnet, mac: mac))
		net.macAddress = mac
		c.networkDevices = [net]

		c.keyboards = [VZUSBKeyboardConfiguration()]
		c.pointingDevices = [VZUSBScreenCoordinatePointingDeviceConfiguration()]
		c.entropyDevices = [VZVirtioEntropyDeviceConfiguration()]
		if spec.vsock { c.socketDevices = [VZVirtioSocketDeviceConfiguration()] }
		if spec.inputs {
			// Placeholder share (an empty dir); each lease swaps in its own folder after restore.
			try FileManager.default.createDirectory(at: spec.emptyShare, withIntermediateDirectories: true)
			let fs = VZVirtioFileSystemDeviceConfiguration(tag: VZVirtioFileSystemDeviceConfiguration.macOSGuestAutomountTag)
			fs.share = VZSingleDirectoryShare(directory: VZSharedDirectory(url: spec.emptyShare, readOnly: true))
			c.directorySharingDevices = [fs]
			c.usbControllers = [VZXHCIControllerConfiguration()]  // no devices at freeze
		}

		try c.validate()
		try c.validateSaveRestoreSupport()
		return CapsuleVM(VZVirtualMachine(configuration: c))
	}

	// MARK: vmnet

	/// A network only lives in the process that created it, so each run recreates it from the subnet.
	private static var networks: [Int: vmnet_network_ref] = [:]

	private static func inAddr(_ s: String) throws -> in_addr {
		var a = in_addr()
		guard inet_pton(AF_INET, s, &a) == 1 else { throw BayError("bad IPv4 \(s)") }
		return a
	}

	private static func check(_ r: vmnet_return_t, _ what: String) throws {
		guard r == .VMNET_SUCCESS else { throw BayError("vmnet \(what): \(r.rawValue)") }
	}

	/// 10.77.N.0/24 with the guest pinned to .2 by a DHCP reservation on its MAC. No port forward:
	/// vmnet's forward listens on every host interface, the LAN included; the host reaches
	/// the guest IP directly, and one pf anchor fences all of 10.77.0.0/16 off the LAN.
	static func vmnetNetwork(subnet: Int, mac: VZMACAddress) throws -> vmnet_network_ref {
		if let n = networks[subnet] { return n }
		let net = CapsuleNetwork(subnet: subnet)
		var status: vmnet_return_t = .VMNET_SUCCESS
		guard let config = vmnet_network_configuration_create(.VMNET_SHARED_MODE, &status) else {
			throw BayError("vmnet configuration: \(status.rawValue)")
		}
		var gateway = try inAddr(net.gateway)
		var mask = try inAddr("255.255.255.0")
		try check(vmnet_network_configuration_set_ipv4_subnet(config, &gateway, &mask), "subnet")
		vmnet_network_configuration_disable_nat66(config)
		var ether = ether_addr_t()
		withUnsafeMutableBytes(of: &ether.octet) { buf in
			for (i, b) in mac.string.split(separator: ":").enumerated() where i < 6 { buf[i] = UInt8(b, radix: 16) ?? 0 }
		}
		var guest = try inAddr(net.guestIP)
		try check(vmnet_network_configuration_add_dhcp_reservation(config, &ether, &guest), "dhcp reservation")
		// Fails with 1001 when the binary lives under ~/Documents (TCC); build-bay.sh installs to ~/.cryo/bin.
		guard let network = vmnet_network_create(config, &status) else {
			throw VMNetUnavailable(subnet: subnet, status: status.rawValue)
		}
		networks[subnet] = network
		return network
	}

	// MARK: Operations

	public func restore(from state: URL) async throws { try await vm.restoreMachineStateFrom(url: state) }
	/// Cold boot.
	public func start() async throws { try await vm.start() }
	public func resume() async throws { try await vm.resume() }
	public func pause() async throws { try await vm.pause() }
	public func save(to state: URL) async throws { try await vm.saveMachineStateTo(url: state) }
	/// Host `stop()`, never a guest shutdown.
	public func stop() async throws { try await vm.stop() }

	// MARK: Teardown

	/// Every VM this process created. A process that exits with a VM still running leaves its vmnet
	/// subnet claimed by InternetSharing, so every exit path stops them first.
	/// Weak: holding a stopped VM keeps its disk attachments (and their file locks) alive, which made
	/// the restore right after a freeze fail with VZErrorDomain 1 ("Cannot acquire shared lock").
	final class WeakVM {
		weak var vm: VZVirtualMachine?
		init(_ vm: VZVirtualMachine) { self.vm = vm }
	}
	static var live: [WeakVM] = []
	private static var signalSources: [DispatchSourceSignal] = []

	public static func stopAll() async {
		for vm in live.compactMap(\.vm) where vm.state != .stopped && vm.state != .error {
			try? await vm.stop()
		}
		live.removeAll()
	}

	/// Runs on a signal before the VMs stop: the bay's shutdown, so no refill thaws a new VM meanwhile.
	public static var beforeSignalExit: (@MainActor () async -> Void)?

	/// SIGINT/SIGTERM/SIGHUP stop every VM, then exit, so vmnet subnets aren't leaked.
	public static func installExitHandlers(log: @escaping @Sendable (String) -> Void = { print($0) }) {
		guard signalSources.isEmpty else { return }
		for sig in [SIGINT, SIGTERM, SIGHUP] {
			signal(sig, SIG_IGN)
			let src = DispatchSource.makeSignalSource(signal: sig, queue: .main)
			src.setEventHandler {
				Task { @MainActor in
					log("\nsignal \(sig): stopping \(live.compactMap(\.vm).count) VM(s)")
					await beforeSignalExit?()
					await stopAll()
					exit(128 + sig)
				}
			}
			src.resume()
			signalSources.append(src)
		}
	}

	private static var activity: NSObjectProtocol?

	/// Keeps macOS from throttling a VM process (App Nap, background QoS, low disk priority); it
	/// slowed save/restore 10-20x for others (developer.apple.com/forums/thread/828750).
	public static func prepareProcess() {
		guard activity == nil else { return }
		activity = ProcessInfo.processInfo.beginActivity(
			options: [.userInitiated, .latencyCritical, .idleSystemSleepDisabled], reason: "cryo VM save/restore")
		setiopolicy_np(IOPOL_TYPE_DISK, IOPOL_SCOPE_PROCESS, IOPOL_IMPORTANT)
	}

	/// Runs `body` with exit handlers installed and every VM stopped afterwards, errors included.
	public static func session<T>(_ body: () async throws -> T) async throws -> T {
		prepareProcess()
		installExitHandlers()
		do {
			let r = try await body()
			await stopAll()
			return r
		} catch {
			await stopAll()
			throw error
		}
	}
}

// MARK: - Manifest check and thaw

/// A capsule restored (or cold booted) into a lease directory, paused if restored.
public struct ThawedCapsule {
	public let cvm: CapsuleVM
	public let lease: LeaseFiles
	public let restoreMS: Double
	/// Why restore wasn't used; nil when the state was restored.
	public let fallbackReason: String?
	public var coldBooted: Bool { fallbackReason != nil }
}

extension CapsuleManifest {
	/// The stamps a manifest records for the files a saved state depends on. Existing manifests use these key names.
	public static func stamps(image: ImageFiles, capsule: CapsuleFiles) -> [String: String] {
		[
			"base": Host.stamp(image.base),
			"hardware-model": Host.stamp(image.hardwareModel),
			"freeze-layer": Host.stamp(capsule.freezeLayer),
			"machine-id": Host.stamp(capsule.machineID),
		]
	}

	/// Reasons this capsule's saved state shouldn't be restored here; empty means fine. A mismatch
	/// cold boots instead of failing with an opaque VZError.
	public func mismatches(image: ImageFiles, capsule: CapsuleFiles, digest: String) -> [String] {
		var out: [String] = []
		if ProcessInfo.processInfo.environment["CRYO_FORCE_FALLBACK"] != nil { out.append("CRYO_FORCE_FALLBACK set") }
		func check(_ what: String, _ frozen: String, _ now: String) {
			if frozen != now { out.append("\(what): frozen \(frozen), now \(now)") }
		}
		check("host", host, Host.fingerprint())
		check("image", self.image, digest)
		let macNow = (try? String(contentsOf: capsule.mac, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)) ?? "missing"
		check("mac", mac.lowercased(), macNow.lowercased())
		let now = Self.stamps(image: image, capsule: capsule)
		for (k, v) in files.sorted(by: { $0.key < $1.key }) { check(k, v, now[k] ?? "unknown") }
		return out
	}
}

extension CapsuleVM {
	/// Builds the VM on a fresh lease directory (aux clone + overlay) and restores the capsule's
	/// state into it, paused. On a manifest mismatch or a failed restore, cold boots from the
	/// capsule's own disks instead (base + freeze layer + fresh overlay), like power loss.
	/// `coldBoot` skips the restore for that reason (restored guests that never got ready).
	public static func thaw(
		paths: BayPaths, image: ImageFiles, digest: String, capsule: CapsuleFiles, manifest: CapsuleManifest, leaseID: String,
		coldBoot: String? = nil
	) async throws -> ThawedCapsule {
		let lease = paths.lease(leaseID)
		let fm = FileManager.default
		try? fm.removeItem(at: lease.dir)
		do {
			return try await thaw(
				into: lease, paths: paths, image: image, digest: digest, capsule: capsule, manifest: manifest, coldBoot: coldBoot)
		} catch {
			// No failure leaves an aux clone and overlay behind: a capsule stuck on a taken subnet
			// (VMNetUnavailable from `make`) retries every minute.
			try? fm.removeItem(at: lease.dir)
			throw error
		}
	}

	private static func thaw(
		into lease: LeaseFiles, paths: BayPaths, image: ImageFiles, digest: String, capsule: CapsuleFiles, manifest: CapsuleManifest,
		coldBoot: String?
	) async throws -> ThawedCapsule {
		let fm = FileManager.default
		try fm.createDirectory(at: lease.dir, withIntermediateDirectories: true)
		let spec = VMSpec(image: image, capsule: capsule, manifest: manifest, aux: lease.aux, emptyShare: paths.emptyShare)
		try fm.copyItem(at: capsule.aux, to: lease.aux)  // APFS clone
		var reason = coldBoot ?? manifest.mismatches(image: image, capsule: capsule, digest: digest).joined(separator: "; ")
		let t1 = uptimeNS()
		if reason.isEmpty {
			let cvm = try make(spec, disk: try leaseDisk(image: image, capsule: capsule, overlay: lease.overlay))
			do {
				try await cvm.restore(from: capsule.state)
				return ThawedCapsule(cvm: cvm, lease: lease, restoreMS: elapsedMS(t1, uptimeNS()), fallbackReason: nil)
			} catch {
				// Over the host's VM limit a cold boot fails the same way; let the watchdog see it.
				if FailureKind.of(error) == .vmLimit { throw error }
				let e = error as NSError
				reason = "restore failed: \(e.domain) \(e.code) \(e.localizedDescription)"
			}
		}
		BayLog.vm.error("capsule \(capsule.number): cold boot fallback (\(reason, privacy: .public))")
		// The failed VM still holds the overlay and aux; clear both before building the cold boot VM.
		try? fm.removeItem(at: lease.overlay)
		try? fm.removeItem(at: lease.aux)
		try fm.copyItem(at: capsule.aux, to: lease.aux)
		let cold = try make(spec, disk: try leaseDisk(image: image, capsule: capsule, overlay: lease.overlay))
		try await cold.start()
		return ThawedCapsule(cvm: cold, lease: lease, restoreMS: elapsedMS(t1, uptimeNS()), fallbackReason: reason)
	}

	/// Release: host stop, then the lease files go.
	public static func release(_ t: ThawedCapsule) async {
		try? await t.cvm.stop()
		try? FileManager.default.removeItem(at: t.lease.dir)
	}
}

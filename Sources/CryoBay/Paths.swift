import Foundation

/// The bay's files under `~/.cryo` (docs/spec/capsule.md "Files"). Everything lives outside
/// `~/Documents`, which vmnet refuses.
public struct BayPaths: Sendable {
	public let root: URL

	public init(root: URL) { self.root = root }

	/// `~/.cryo`, or `$CRYO_HOME` when set (tests and side-by-side bays).
	public static func standard(environment: [String: String] = ProcessInfo.processInfo.environment) -> BayPaths {
		if let home = environment["CRYO_HOME"], !home.isEmpty {
			return BayPaths(root: URL(filePath: home, directoryHint: .isDirectory))
		}
		return BayPaths(root: FileManager.default.homeDirectoryForCurrentUser.appending(path: ".cryo", directoryHint: .isDirectory))
	}

	public var config: URL { root.appending(path: "config.toml") }
	public var socket: URL { root.appending(path: "bay.sock") }
	/// The LaunchAgent's stdout and stderr (`cryo bay install`).
	public var log: URL { root.appending(path: "bay.log") }
	public var bin: URL { root.appending(path: "bin", directoryHint: .isDirectory) }
	public var images: URL { root.appending(path: "images", directoryHint: .isDirectory) }
	public var capsules: URL { root.appending(path: "capsules", directoryHint: .isDirectory) }
	public var leases: URL { root.appending(path: "leases", directoryHint: .isDirectory) }
	public var caches: URL { root.appending(path: "caches", directoryHint: .isDirectory) }
	/// `run/<pid>`, locked by each `cryo bay` command running VMs on this root (Cleanup.registerVMProcess).
	public var run: URL { root.appending(path: "run", directoryHint: .isDirectory) }
	/// Locked by the bay for its whole life, so a second bay on this root refuses (Cleanup.lockBay).
	public var bayLock: URL { root.appending(path: "bay.lock") }
	/// Empty directory used as the placeholder virtiofs share while a capsule is not leased.
	public var emptyShare: URL { root.appending(path: "empty-share", directoryHint: .isDirectory) }

	public func image(_ digest: String) -> ImageFiles { ImageFiles(dir: images.appending(path: digest, directoryHint: .isDirectory)) }
	public func capsule(_ n: Int) -> CapsuleFiles { CapsuleFiles(dir: capsules.appending(path: String(n), directoryHint: .isDirectory), number: n) }
	public func lease(_ id: String) -> LeaseFiles { LeaseFiles(dir: leases.appending(path: id, directoryHint: .isDirectory)) }
	public func cache(_ name: String) -> URL { caches.appending(path: "\(name).asif") }

	/// Creates the directory tree and marks it for Spotlight to skip.
	public func prepare() throws {
		let fm = FileManager.default
		for d in [root, bin, images, capsules, leases, caches, emptyShare] {
			try fm.createDirectory(at: d, withIntermediateDirectories: true)
		}
		let marker = root.appending(path: ".metadata_never_index")
		if !fm.fileExists(atPath: marker.path) { fm.createFile(atPath: marker.path, contents: nil) }
	}
}

/// One golden image: `images/<digest>/`.
public struct ImageFiles: Sendable {
	public let dir: URL
	/// Read-only golden base disk.
	public var base: URL { dir.appending(path: "base.asif") }
	public var hardwareModel: URL { dir.appending(path: "hardware-model.bin") }
	/// The golden identity's aux storage; a new capsule starts from a clone of it.
	public var auxTemplate: URL { dir.appending(path: "aux.img") }
	/// `ImageInfo` as JSON.
	public var info: URL { dir.appending(path: "image.json") }
	/// The bay's own key for the image's `cryo` user (setup, refill, warm-up logins). Leases get their own keys.
	public var guestKey: URL { dir.appending(path: "id_ed25519") }
}

/// One capsule: `capsules/<N>/`. Identity files never change after the freeze.
public struct CapsuleFiles: Sendable {
	public let dir: URL
	public let number: Int
	public var aux: URL { dir.appending(path: "aux.img") }
	public var machineID: URL { dir.appending(path: "machine-id.bin") }
	/// MAC address as text, e.g. `12:ab:cd:10:20:31`.
	public var mac: URL { dir.appending(path: "mac.txt") }
	/// Thin layer over the image base written during this capsule's freeze; read-only after.
	public var freezeLayer: URL { dir.appending(path: "freeze.asif") }
	/// Saved machine state (encrypted to this host and user).
	public var state: URL { dir.appending(path: "state.vzstate") }
	/// `CapsuleManifest` as JSON: what the state was frozen with, checked before every restore.
	public var manifest: URL { dir.appending(path: "manifest.json") }
}

/// One lease: `leases/<id>/`, deleted on release.
public struct LeaseFiles: Sendable {
	public let dir: URL
	/// This lease's copy of the capsule's aux storage (APFS clone).
	public var aux: URL { dir.appending(path: "aux.img") }
	/// Copy-on-write layer over base + freeze layer.
	public var overlay: URL { dir.appending(path: "overlay.asif") }
	/// The lease folder, shared into the guest at `/Volumes/My Shared Files`.
	public var folder: URL { dir.appending(path: "folder", directoryHint: .isDirectory) }
	/// Clone of `caches/<name>.asif`, hot-plugged as USB.
	public var cache: URL { dir.appending(path: "cache.asif") }
}

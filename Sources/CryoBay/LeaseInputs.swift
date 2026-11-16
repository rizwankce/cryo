import Darwin
import Foundation
import Virtualization

/// What a lease brings into the guest: a folder (virtiofs share swap) and a cache disk
/// (USB hot-plug). Pure helpers first, VM calls below.
enum LeaseInputs {
	// MARK: Names

	/// Cache names become file names under `caches/`, so the set is narrow: `[a-z0-9._-]{1,64}`, and
	/// not a dot-only name (`.` and `..` would escape the directory).
	static func validCacheName(_ name: String) -> Bool {
		guard (1...64).contains(name.utf8.count) else { return false }
		guard name.unicodeScalars.allSatisfy({ ("a"..."z").contains($0) || ("0"..."9").contains($0) || $0 == "." || $0 == "_" || $0 == "-" })
		else { return false }
		return !name.allSatisfy { $0 == "." }
	}

	/// `ssh.config` of a lease, exactly the shape api.md shows; the CLI writes the key to `~/.cryo/keys/<id>`
	/// and `ssh.host_key` to `~/.cryo/known_hosts/<id>`. Only that file is consulted and never written,
	/// so `~/.ssh/known_hosts` stays untouched and a reused name can't hit a stale key.
	static func sshConfig(id: String) -> String {
		"Host cryo-\(id)\n  User cryo\n  ProxyCommand cryo ssh \(id)\n  IdentityFile ~/.cryo/keys/\(id)\n"
			+ "  HostKeyAlias cryo-\(id)\n  UserKnownHostsFile ~/.cryo/known_hosts/\(id)\n  GlobalKnownHostsFile /dev/null\n"
			+ "  StrictHostKeyChecking yes"
	}

	/// Single-quotes a string for the guest's shell.
	static func shellQuote(_ s: String) -> String { "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'" }

	static let shareMount = "/Volumes/My Shared Files"
	static let cacheMount = "/Volumes/Cache"
	static let cacheVolumeName = "Cache"
	/// Sparse, so it costs nothing until the guest writes.
	static let newCacheSize = "64g"

	// MARK: Folder

	/// APFS clone of the client's folder (`cp -c -R`): the agent's edits never touch the original.
	/// `clonefile` takes a whole directory tree in one call; a different volume falls back to a copy.
	static func cloneFolder(_ source: URL, to dest: URL) async throws {
		if clonefile(source.path, dest.path, 0) == 0 { return }
		let why = String(cString: strerror(errno))
		let r = await runProcess("/bin/cp", ["-c", "-R", source.path, dest.path])
		guard r.status == 0 else { throw BayError("clone folder \(source.path): \(why); cp: \(r.out)") }
	}

	/// Swaps the placeholder share for the lease folder. Once per lease, before the agent gets it.
	@MainActor
	static func swapShare(_ cvm: CapsuleVM, to folder: URL) throws {
		guard let fs = cvm.vm.directorySharingDevices.first as? VZVirtioFileSystemDevice else {
			throw BayError("capsule has no virtiofs device (frozen without inputs?)")
		}
		fs.share = VZSingleDirectoryShare(directory: VZSharedDirectory(url: folder, readOnly: false))
	}

	/// First entry of the folder, to poll the guest until the new share is visible.
	static func firstEntry(_ folder: URL) -> String? {
		((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []).sorted().first
	}

	// MARK: Cache

	/// Puts the lease's cache disk in place: a clone of `caches/<name>.asif` or a new empty APFS
	/// image with the volume already named `Cache`. Returns true when it is new.
	static func prepareCache(name: String, paths: BayPaths, lease: LeaseFiles) async throws -> Bool {
		let saved = paths.cache(name)
		if FileManager.default.fileExists(atPath: saved.path) {
			try FileManager.default.copyItem(at: saved, to: lease.cache)  // APFS clone
			return false
		}
		let r = await runProcess(
			"/usr/sbin/diskutil",
			["image", "create", "blank", "--format", "ASIF", "--size", newCacheSize, "--fs", "APFS", "--volumeName", cacheVolumeName, lease.cache.path])
		guard r.status == 0 else { throw BayError("create cache disk: \(r.out)") }
		return true
	}

	/// Hot-plugs the cache image as USB mass storage on the capsule's XHCI controller.
	@MainActor
	static func attachCache(_ cvm: CapsuleVM, image: URL) async throws -> VZUSBDevice {
		guard let usb = cvm.vm.usbControllers.first else { throw BayError("capsule has no USB controller") }
		let att = try VZDiskImageStorageDeviceAttachment(url: image, readOnly: false)
		let dev = VZUSBMassStorageDevice(configuration: VZUSBMassStorageDeviceConfiguration(attachment: att))
		try await usb.attach(device: dev)
		return dev
	}

	@MainActor
	static func detachCache(_ cvm: CapsuleVM, device: VZUSBDevice) async throws {
		guard let usb = cvm.vm.usbControllers.first else { return }
		try await usb.detach(device: device)
	}

	/// Replaces `caches/<name>.asif` with the lease's copy: rename(2) over the old file is atomic.
	static func saveCache(name: String, paths: BayPaths, lease: LeaseFiles) throws {
		try FileManager.default.createDirectory(at: paths.caches, withIntermediateDirectories: true)
		guard rename(lease.cache.path, paths.cache(name).path) == 0 else {
			throw BayError("save cache \(name): \(String(cString: strerror(errno)))")
		}
	}

	/// The external physical disk the hot-plugged cache shows up as, from `diskutil list external
	/// physical` output. Only when exactly one exists, so a format can never hit another disk.
	static func externalDisk(from listing: String) -> String? {
		let disks = listing.split(separator: "\n").compactMap { line -> String? in
			guard line.hasPrefix("/dev/disk"), line.contains("external"), line.contains("physical") else { return nil }
			return line.split(separator: " ").first.map(String.init)
		}
		return disks.count == 1 ? disks[0] : nil
	}

	/// Waits for the guest to mount `/Volumes/Cache` and make it writable. A brand-new image the host
	/// couldn't pre-format gets `diskutil eraseDisk` on the one external disk.
	@MainActor
	static func waitForCache(guest: Guest, isNew: Bool) async throws {
		func mounted() async -> Bool { await guest.ssh("test -d \(cacheMount)").status == 0 }
		do {
			try await waitFor("\(cacheMount) to mount", timeout: isNew ? 8 : 30, every: 0.1) { await mounted() }
		} catch  where isNew {
			let list = await guest.ssh("diskutil list external physical").out
			guard let disk = externalDisk(from: list) else { throw BayError("no single external disk to format as Cache:\n\(list)") }
			let r = await guest.ssh("diskutil eraseDisk APFS \(cacheVolumeName) GPT \(disk)", timeout: 120)
			guard r.status == 0 else { throw BayError("format \(disk): \(r.out)") }
			try await waitFor("\(cacheMount) to mount", timeout: 30, every: 0.1) { await mounted() }
		}
		// External volumes can come up with ownership ignored or owned by another uid.
		let w = await guest.ssh("test -w \(cacheMount) || sudo -n chown cryo \(cacheMount); test -w \(cacheMount)")
		guard w.status == 0 else { throw BayError("\(cacheMount) is not writable by cryo: \(w.out)") }
	}
}

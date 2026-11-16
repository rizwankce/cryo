import CryptoKit
import DiskImageKit
import Foundation
import Virtualization

/// An image's digest: the first 16 hex chars of SHA-256 over hardware-model.bin then base.asif
/// (docs/spec/image.md "Identity and use").
enum ImageDigest {
	static let length = 16
	static let chunk = 16 << 20

	/// Reads ~50 GB (~1 min), so callers on the main actor use `offMain`.
	static func compute(hardwareModel: URL, base: URL) throws -> String {
		var hasher = SHA256()
		for url in [hardwareModel, base] {
			let h = try FileHandle(forReadingFrom: url)
			defer { try? h.close() }
			// Don't fill the page cache with 51 GB we read exactly once.
			_ = fcntl(h.fileDescriptor, F_NOCACHE, 1)
			while let data = try h.read(upToCount: chunk), !data.isEmpty { hasher.update(data: data) }
		}
		return String(hasher.finalize().map { String(format: "%02x", $0) }.joined().prefix(length))
	}

	/// Off the main actor: the signal handlers are main-actor tasks, so Ctrl-C did nothing while
	/// the hash ran there.
	static func offMain(hardwareModel: URL, base: URL) async throws -> String {
		try await Task.detached(priority: .userInitiated) { try compute(hardwareModel: hardwareModel, base: base) }.value
	}
}

/// `cryo image build`: the golden image recipe (docs/spec/image.md "Build"):
/// install macOS from the restore image → guest provisioning → Xcode → one Simulator runtime →
/// the user's script → shut down, hash, `images/<digest>/`. Put capsules on it afterwards with
/// `cryo image use <digest>`; the warm-up build goes in at freeze.
enum ImageBuild {
	/// The build VM's vmnet subnet unless `--subnet` says otherwise; `cryo image use` never gives it
	/// to a capsule, so the next build finds it free.
	static let defaultSubnet = 9

	struct Options {
		var ipsw: URL?
		var xcode: XcodeSource?
		/// `xcodebuild -downloadPlatform` value; nil for none. One runtime only.
		var runtime: String?
		var setup: URL?
		var tag: String?
		var diskGB = 80
		/// vmnet subnet of the build VM (10.77.S.0/24). Must not be a capsule's subnet.
		var subnet = ImageBuild.defaultSubnet
	}

	enum XcodeSource {
		case app(URL)
		case xip(URL)
	}

	/// Where the build VM keeps what isn't part of the finished image.
	struct BuildFiles {
		let image: ImageFiles
		var dir: URL { image.dir }
		var machineID: URL { dir.appending(path: "machine-id.bin") }
		var mac: URL { dir.appending(path: "mac.txt") }
		var password: URL { dir.appending(path: "password.txt") }
		var askpass: URL { dir.appending(path: "askpass.sh") }
		/// Build-only files, deleted before the image is put in place.
		var scratch: [URL] { [machineID, mac, password, askpass] }
	}

	// MARK: - Restore image

	static let catalog = URL(string: "https://mesu.apple.com/assets/macos/com_apple_macOSIPSW/com_apple_macOSIPSW.xml")!

	struct Restore: Equatable {
		var version: String
		var build: String
		var url: URL
	}

	/// The newest restore image for virtual Macs (`VirtualMac2,1`) in Apple's IPSW catalog.
	/// `VZMacOSRestoreImage.fetchLatestSupported` failed inside the sandbox; the catalog works.
	static func latest(catalog data: Data) throws -> Restore {
		guard let root = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
			let epochs = root["MobileDeviceSoftwareVersionsByVersion"] as? [String: Any]
		else { throw BayError("IPSW catalog: unexpected format") }
		var best: Restore?
		for case let epoch as [String: Any] in epochs.values {
			guard let models = epoch["MobileDeviceSoftwareVersions"] as? [String: Any],
				let builds = models["VirtualMac2,1"] as? [String: Any]
			else { continue }
			for case let build as [String: Any] in builds.values {
				guard let r = build["Restore"] as? [String: Any], let v = r["ProductVersion"] as? String,
					let b = r["BuildVersion"] as? String, let s = r["FirmwareURL"] as? String, let url = URL(string: s)
				else { continue }
				if best == nil || newer(v, than: best!.version) { best = Restore(version: v, build: b, url: url) }
			}
		}
		guard let best else { throw BayError("IPSW catalog lists no restore image for virtual Macs") }
		return best
	}

	/// Numeric version compare: 27.10 is newer than 27.9.
	static func newer(_ a: String, than b: String) -> Bool {
		let x = a.split(separator: ".").map { Int($0) ?? 0 }
		let y = b.split(separator: ".").map { Int($0) ?? 0 }
		for i in 0..<max(x.count, y.count) where (i < x.count ? x[i] : 0) != (i < y.count ? y[i] : 0) {
			return (i < x.count ? x[i] : 0) > (i < y.count ? y[i] : 0)
		}
		return false
	}

	/// Downloads the newest IPSW into `~/.cryo/ipsw/` once (~26 GB); later builds reuse it.
	@MainActor
	static func downloadLatest(paths: BayPaths, out: BayCommand.Writer) async throws -> URL {
		let cat = await runProcess("/usr/bin/curl", ["-fsSL", catalog.absoluteString])
		guard cat.status == 0 else { throw BayError("IPSW catalog: \(cat.out)") }
		let r = try latest(catalog: Data(cat.out.utf8))
		let dir = paths.root.appending(path: "ipsw", directoryHint: .isDirectory)
		try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
		let file = dir.appending(path: r.url.lastPathComponent)
		if FileManager.default.fileExists(atPath: file.path) {
			out("macOS \(r.version) (\(r.build)): \(file.path) already downloaded\n")
			return file
		}
		out("downloading macOS \(r.version) (\(r.build)) restore image (~26 GB) to \(file.path)...\n")
		let part = file.appendingPathExtension("part")
		// -C -: resume a download that was cut off.
		let dl = await runProcess("/usr/bin/curl", ["-fsSL", "-C", "-", "-o", part.path, r.url.absoluteString])
		guard dl.status == 0 else { throw BayError("download \(r.url): \(dl.out)") }
		try FileManager.default.moveItem(at: part, to: file)
		return file
	}

	// MARK: - Guest scripts (shell, run over SSH as `cryo`)

	/// After provisioning: no sleep, Spotlight off, no automatic updates.
	static let settingsCommands = [
		"sudo pmset -a sleep 0 displaysleep 0 disksleep 0 powernap 0",
		"sudo mdutil -a -i off",
		"sudo softwareupdate --schedule off",
	]

	/// After Xcode is in /Applications: licence,
	/// first launch, one Simulator runtime (no Apple ID). Prints the versions for image.json.
	static func xcodeScript(runtime: String?) -> String {
		var s = """
			set -e
			sudo xcode-select -s /Applications/Xcode.app
			sudo xcodebuild -license accept
			sudo xcodebuild -runFirstLaunch

			"""
		if let runtime { s += "xcodebuild -downloadPlatform \(runtime)\n" }
		s += """
			xcodebuild -version
			xcrun simctl runtime list

			"""
		return s
	}

	/// `27.2 (27B52)` from `xcodebuild -version` output.
	static func xcodeVersion(_ output: String) -> String? {
		var version: String?
		var build: String?
		for line in output.split(separator: "\n") {
			if line.hasPrefix("Xcode ") { version = String(line.dropFirst(6)).trimmingCharacters(in: .whitespaces) }
			if line.hasPrefix("Build version ") { build = String(line.dropFirst(14)).trimmingCharacters(in: .whitespaces) }
		}
		guard let version else { return nil }
		return build.map { "\(version) (\($0))" } ?? version
	}

	// MARK: - Steps

	/// The build VM: the golden identity on the read-write base, on its own vmnet subnet.
	@MainActor
	static func makeVM(_ f: BuildFiles, paths: BayPaths, subnet: Int) throws -> CapsuleVM {
		let disk = try VZDiskImageStorageDeviceAttachment(diskImage: try DiskImage(opening: OpenConfiguration(url: f.image.base, mode: .readWrite)))
		let mac = try String(contentsOf: f.mac, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
		let spec = VMSpec(
			hardwareModel: f.image.hardwareModel, machineID: f.machineID, mac: mac, aux: f.image.auxTemplate, cpus: 4, memoryGB: 8,
			subnet: subnet, vsock: false, inputs: false, emptyShare: paths.emptyShare)
		return try CapsuleVM.make(spec, disk: disk)
	}

	/// Install: identity, aux, empty ASIF disk, key and password, then the installer (~5 min).
	@MainActor
	static func install(ipsw: URL, _ f: BuildFiles, paths: BayPaths, o: Options, out: BayCommand.Writer) async throws -> String {
		let image = try await VZMacOSRestoreImage.image(from: ipsw)
		guard let req = image.mostFeaturefulSupportedConfiguration else { throw BayError("this Mac can't run the macOS in \(ipsw.lastPathComponent)") }
		let v = image.operatingSystemVersion
		let macOS = "\(v.majorVersion).\(v.minorVersion)\(v.patchVersion > 0 ? ".\(v.patchVersion)" : "") (\(image.buildVersion))"
		out("installing macOS \(macOS) on a \(o.diskGB) GB disk...\n")

		try req.hardwareModel.dataRepresentation.write(to: f.image.hardwareModel)
		try VZMacMachineIdentifier().dataRepresentation.write(to: f.machineID)
		try VZMACAddress.randomLocallyAdministered().string.write(to: f.mac, atomically: true, encoding: .utf8)
		_ = try VZMacAuxiliaryStorage(creatingStorageAt: f.image.auxTemplate, hardwareModel: req.hardwareModel, options: [.allowOverwrite])
		_ = try DiskImage(creating: ASIFCreationConfiguration.asif(url: f.image.base, blockCount: (o.diskGB << 30) / 512, blockSize: .bytes512))

		let kg = await runProcess("/usr/bin/ssh-keygen", ["-q", "-t", "ed25519", "-N", "", "-C", "cryo-image", "-f", f.image.guestKey.path])
		guard kg.status == 0 else { throw BayError("ssh-keygen: \(kg.out)") }
		let alnum = Array("abcdefghjkmnpqrstuvwxyzABCDEFGHJKMNPQRSTUVWXYZ23456789")
		try String((0..<20).map { _ in alnum.randomElement()! }).write(to: f.password, atomically: true, encoding: .utf8)
		try "#!/bin/sh\ncat '\(f.password.path)'\n".write(to: f.askpass, atomically: true, encoding: .utf8)
		try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: f.askpass.path)
		try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: f.password.path)

		let cvm = try makeVM(f, paths: paths, subnet: o.subnet)
		let installer = VZMacOSInstaller(virtualMachine: cvm.vm, restoringFromImageAt: ipsw)
		// The observer outlives nothing: it's invalidated before install() returns to the caller.
		try await withoutActuallyEscaping(out) { log in
			nonisolated(unsafe) let log = log
			nonisolated(unsafe) var last = -1
			let obs = installer.progress.observe(\.fractionCompleted) { p, _ in
				let pct = Int(p.fractionCompleted * 100)
				if pct != last && pct % 10 == 0 {
					last = pct
					log("  install \(pct)%\n")
				}
			}
			defer { obs.invalidate() }
			try await installer.install()
		}
		return macOS
	}

	/// Provision: first boot with guest provisioning (user `cryo`, auto-login, SSH), then the
	/// key over a password login, passwordless sudo and the settings; shuts down when done.
	@MainActor
	static func provision(_ f: BuildFiles, paths: BayPaths, o: Options, out: BayCommand.Writer) async throws {
		let password = try String(contentsOf: f.password, encoding: .utf8)
		let p = VZMacGuestProvisioningOptions()
		p.fullName = "Cryo"
		p.username = Guest.user
		p.password = password
		p.logsInAutomatically = true
		p.enablesRemoteLogin = true
		let start = VZMacOSVirtualMachineStartOptions()
		try start.setGuestProvisioning(p)
		let cvm = try await startVM(f, paths: paths, subnet: o.subnet, options: start)

		let mac = try String(contentsOf: f.mac, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
		var guest = Guest(ip: CapsuleNetwork(subnet: o.subnet).guestIP, key: f.image.guestKey)
		try await waitFor("SSH port (Setup Assistant runs unattended)", timeout: 1200, every: 1) {
			guest = Guest(ip: DHCPLeases.guestIP(mac: mac, subnet: o.subnet), key: f.image.guestKey)
			return await guest.probe()
		}
		// The password login is only for the key; every later login uses the key.
		let passwordSSH = [
			"-F", "/dev/null", "-o", "StrictHostKeyChecking=no", "-o", "UserKnownHostsFile=/dev/null", "-o", "LogLevel=ERROR",
			"-o", "ConnectTimeout=2", "-o", "GSSAPIAuthentication=no", "-o", "IdentityAgent=none", "-o", "PubkeyAuthentication=no",
			"-o", "PreferredAuthentications=keyboard-interactive,password", "-o", "NumberOfPasswordPrompts=1", "\(Guest.user)@\(guest.ip)",
			"mkdir -p ~/.ssh && chmod 700 ~/.ssh && cat >> ~/.ssh/authorized_keys && chmod 600 ~/.ssh/authorized_keys",
		]
		let pub = try Data(contentsOf: f.image.guestKey.appendingPathExtension("pub"))
		let env = ["SSH_ASKPASS": f.askpass.path, "SSH_ASKPASS_REQUIRE": "force", "DISPLAY": ":0"]
		try await waitFor("password SSH login", timeout: 300, every: 3) {
			await runProcess("/usr/bin/ssh", passwordSSH, stdin: pub, env: env).status == 0
		}
		var r = await guest.ssh(
			"echo \(password) | sudo -S -p '' sh -c \"echo 'cryo ALL=(ALL) NOPASSWD: ALL' > /etc/sudoers.d/cryo && chmod 440 /etc/sudoers.d/cryo\"")
		guard r.status == 0 else { throw BayError("sudoers: \(r.out)") }
		for cmd in settingsCommands {
			// `mdutil -a -i off` alone takes over 30 s on a fresh install.
			r = await guest.ssh(cmd, timeout: 600)
			guard r.status == 0 else { throw BayError("\(cmd): \(r.out)") }
		}
		try await shutDown(cvm, guest)
	}

	/// Boots the provisioned image read-write and waits for a key login.
	@MainActor
	static func boot(_ f: BuildFiles, paths: BayPaths, o: Options) async throws -> (CapsuleVM, Guest) {
		let cvm = try await startVM(f, paths: paths, subnet: o.subnet)
		let mac = try String(contentsOf: f.mac, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
		var guest = Guest(ip: CapsuleNetwork(subnet: o.subnet).guestIP, key: f.image.guestKey)
		try await waitFor("SSH login", timeout: 600, every: 0.5) {
			guest = Guest(ip: DHCPLeases.guestIP(mac: mac, subnet: o.subnet), key: f.image.guestKey)
			return await guest.ssh("true").status == 0
		}
		return (cvm, guest)
	}

	/// Makes and starts the build VM. The previous VM's service lets go of the aux file a moment after
	/// that VM stops: starting right after the install failed "Failed to lock auxiliary storage"
	/// (EAGAIN), so that error is retried for up to 30 s.
	@MainActor
	static func startVM(
		_ f: BuildFiles, paths: BayPaths, subnet: Int, options: VZMacOSVirtualMachineStartOptions? = nil
	) async throws -> CapsuleVM {
		let deadline = Date().addingTimeInterval(30)
		while true {
			let cvm = try makeVM(f, paths: paths, subnet: subnet)
			do {
				if let options { try await cvm.vm.start(options: options) } else { try await cvm.start() }
				return cvm
			} catch  where auxLocked(error) && Date() < deadline {
				try await Task.sleep(for: .milliseconds(500))
			}
		}
	}

	/// VZErrorDomain 2 with POSIX EAGAIN underneath: another VM (service) still holds the aux file's lock.
	static func auxLocked(_ error: Error) -> Bool {
		let e = error as NSError
		guard e.domain == VZErrorDomain, e.code == 2, let u = e.userInfo[NSUnderlyingErrorKey] as? NSError else { return false }
		return u.domain == NSPOSIXErrorDomain && u.code == Int(EAGAIN)
	}

	/// Guest shutdown from inside so the disk is clean; host stop if it hangs.
	@MainActor
	static func shutDown(_ cvm: CapsuleVM, _ guest: Guest) async throws {
		await guest.ssh("sudo shutdown -h now")
		if (try? await waitFor("guest power off", timeout: 180, every: 1) { cvm.state == .stopped }) == nil {
			try await cvm.stop()
		}
	}

	/// The host's Xcode for `--xcode`: the selected one if it's an app, else /Applications/Xcode.app.
	static func hostXcode() async throws -> URL {
		let sel = await runProcess("/usr/bin/xcode-select", ["-p"]).out.trimmingCharacters(in: .whitespacesAndNewlines)
		if let r = sel.range(of: ".app/Contents/Developer"), sel.hasSuffix(".app/Contents/Developer") {
			return URL(filePath: String(sel[..<r.lowerBound]) + ".app", directoryHint: .isDirectory)
		}
		let app = URL(filePath: "/Applications/Xcode.app", directoryHint: .isDirectory)
		guard FileManager.default.fileExists(atPath: app.path) else {
			throw BayError(
				"""
				--xcode: no Xcode on this Mac. Install Xcode from the App Store, or download the .xip from
				developer.apple.com (needs an Apple ID) and pass --xcode-xip <path>. Cryo never asks for an Apple ID.
				""")
		}
		return app
	}

	/// Copies an Xcode app into the guest's /Applications/Xcode.app: tar over SSH (3.4 GB in ~4 min).
	@MainActor
	static func copyXcode(_ app: URL, guest: Guest) async throws {
		let name = app.lastPathComponent
		let move = name == "Xcode.app" ? "" : " && sudo rm -rf /Applications/Xcode.app && sudo mv '/Applications/\(name)' /Applications/Xcode.app"
		// One log pipe each: Process.run() closes the parent's write end of a pipe it hands out, so a
		// pipe shared by both processes crashed the second run() (NSFileHandleOperationException).
		let tar = Process()
		let ssh = Process()
		let pipe = Pipe()
		let tarLog = Pipe()
		let sshLog = Pipe()
		tar.executableURL = URL(filePath: "/usr/bin/tar")
		tar.arguments = ["-C", app.deletingLastPathComponent().path, "-cf", "-", name]
		tar.standardOutput = pipe
		tar.standardError = tarLog
		ssh.executableURL = URL(filePath: "/usr/bin/ssh")
		ssh.arguments = guest.sshArguments() + ["sudo tar -C /Applications -xf -\(move)"]
		ssh.standardInput = pipe
		ssh.standardOutput = sshLog
		ssh.standardError = sshLog
		try tar.run()
		try ssh.run()
		while tar.isRunning || ssh.isRunning { try await Task.sleep(for: .seconds(1)) }
		guard tar.terminationStatus == 0, ssh.terminationStatus == 0 else {
			let msg = [tarLog, sshLog].map { String(decoding: $0.fileHandleForReading.availableData, as: UTF8.self) }.joined()
			throw BayError("copy Xcode (tar \(tar.terminationStatus), ssh \(ssh.terminationStatus)): \(msg)")
		}
	}

	/// `--xcode-xip`: expanded on the host (in the build dir, so it's on the same volume), then copied like an app.
	static func expandXip(_ xip: URL, into dir: URL) async throws -> URL {
		try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
		let r = await runProcess("/bin/sh", ["-c", "cd \"$1\" && /usr/bin/xip --expand \"$2\"", "sh", dir.path, xip.path])
		guard r.status == 0 else { throw BayError("xip --expand \(xip.path): \(r.out)") }
		let apps = (try FileManager.default.contentsOfDirectory(atPath: dir.path)).filter { $0.hasSuffix(".app") }
		guard let app = apps.first else { throw BayError("\(xip.lastPathComponent) held no .app") }
		return dir.appending(path: app, directoryHint: .isDirectory)
	}

	// MARK: - Build

	@MainActor
	static func build(_ o: Options, paths: BayPaths, out: BayCommand.Writer) async throws -> String {
		let fm = FileManager.default
		try paths.prepare()
		// Check what can fail before the 26 GB download and the install.
		var xcodeApp: URL?
		switch o.xcode {
		case .app(let app): xcodeApp = app
		case .xip(let xip): guard fm.fileExists(atPath: xip.path) else { throw BayError("no file at \(xip.path)") }
		case nil: break
		}
		if let setup = o.setup, !fm.isReadableFile(atPath: setup.path) { throw BayError("can't read \(setup.path)") }
		if let c = ImageUse.capsuleManifests(paths).first(where: { $0.value.network.subnet == o.subnet }) {
			throw BayError("subnet 10.77.\(o.subnet).0/24 belongs to capsule \(c.key); pass another --subnet")
		}
		let ipsw: URL
		if let given = o.ipsw { ipsw = given } else { ipsw = try await downloadLatest(paths: paths, out: out) }

		// A build stopped by a signal exits without the catch below; its leftovers go now (a build
		// still running elsewhere keeps its folder).
		Cleanup.removeDeadBuilds(paths)
		let f = BuildFiles(image: ImageFiles(dir: paths.images.appending(path: ".build-\(getpid())", directoryHint: .isDirectory)))
		try fm.createDirectory(at: f.dir, withIntermediateDirectories: true)
		do {
			let digest = try await CapsuleVM.session {
				var t = Date()
				func step(_ s: String) {
					out("  \(Int(Date().timeIntervalSince(t))) s\n\(s)\n")
					t = Date()
				}
				out("1/5 install\n")
				let macOS = try await install(ipsw: ipsw, f, paths: paths, o: o, out: out)
				step("2/5 provision (user cryo, SSH key, sudo, auto-login, no sleep, no updates, Spotlight off)")
				try await provision(f, paths: paths, o: o, out: out)
				step("3/5 boot the provisioned image")
				let (cvm, guest) = try await boot(f, paths: paths, o: o)
				var xcode: String?
				if o.xcode != nil {
					if case .xip(let xip) = o.xcode {
						out("expanding \(xip.lastPathComponent) on the host...\n")
						xcodeApp = try await expandXip(xip, into: f.dir.appending(path: "xip", directoryHint: .isDirectory))
					}
					step("4/5 Xcode: copy \(xcodeApp!.path), licence, first launch\(o.runtime.map { ", \($0) Simulator runtime" } ?? "")")
					try await copyXcode(xcodeApp!, guest: guest)
					if case .xip = o.xcode { try? fm.removeItem(at: f.dir.appending(path: "xip")) }
					let r = await guest.ssh("/bin/zsh -s", stdin: Data(xcodeScript(runtime: o.runtime).utf8), timeout: nil)
					guard r.status == 0 else { throw BayError("Xcode setup: \(r.out.suffix(800))") }
					xcode = xcodeVersion(r.out)
					out(r.out.split(separator: "\n").filter { $0.hasPrefix("Xcode") || $0.contains("(Ready)") }.map { "  \($0)\n" }.joined())
				} else {
					step("4/5 no Xcode (plain macOS image)")
				}
				if let setup = o.setup {
					step("     \(setup.lastPathComponent) as cryo")
					let r = await guest.ssh(
						"f=$(mktemp /tmp/cryo-setup.XXXXXX) && cat > \"$f\" && chmod 700 \"$f\" && \"$f\"; rc=$?; rm -f \"$f\"; exit $rc",
						stdin: try Data(contentsOf: setup), timeout: nil)
					out(r.out)
					guard r.status == 0 else { throw BayError("\(setup.lastPathComponent) exited \(r.status)") }
				}
				step("5/5 shut down and hash")
				try await shutDown(cvm, guest)
				for u in f.scratch { try? fm.removeItem(at: u) }
				out("  hashing base.asif (~1 min)\n")
				let digest = try await ImageDigest.offMain(hardwareModel: f.image.hardwareModel, base: f.image.base)
				let tag = o.tag ?? (xcode.map { "xcode-\($0.split(separator: " ")[0])" } ?? "macos-\(macOS.split(separator: " ")[0])")
				try BayJSON.write(
					ImageInfo(digest: digest, tag: tag, macOS: macOS, cpus: 4, memoryGB: xcode == nil ? 4 : 8, createdAt: Date(), xcode: xcode),
					to: f.image.info)
				step("image \(digest) (\(tag))")
				return digest
			}
			let dest = paths.image(digest)
			if fm.fileExists(atPath: dest.dir.path) { throw BayError("image \(digest) already exists at \(dest.dir.path)") }
			try fm.moveItem(at: f.dir, to: dest.dir)
			var config = try BayConfig.load(paths.config)
			if config.image == nil {
				config.image = digest
				try config.save(paths.config)
			} else if config.image != digest {
				out("config.toml still uses image \(config.image!)\n")
			}
			return digest
		} catch {
			try? fm.removeItem(at: f.dir)
			throw error
		}
	}

	// MARK: - CLI

	static let usage = """
		usage: cryo image build [--xcode | --xcode-xip <path>] [--runtime iOS|none] [--run ./setup.sh]
		                            [--tag name] [--ipsw <file>] [--disk-gb 80] [--subnet \(defaultSubnet)] [--print-scripts]
		"""

	@MainActor
	static func command(_ args: [String], paths: BayPaths, out: BayCommand.Writer) async throws -> Int32 {
		var o = Options()
		var xcode = false
		var runtime: String?
		var printScripts = false
		var i = 0
		func value(_ flag: String) throws -> String {
			i += 1
			guard i < args.count else { throw BayError("\(flag) needs a value\n\(usage)") }
			return args[i]
		}
		func path(_ s: String) -> URL { URL(filePath: (s as NSString).expandingTildeInPath) }
		while i < args.count {
			switch args[i] {
			case "--xcode": xcode = true
			case "--xcode-xip": o.xcode = .xip(path(try value("--xcode-xip")))
			case "--runtime": runtime = try value("--runtime")
			case "--run": o.setup = path(try value("--run"))
			case "--tag": o.tag = try value("--tag")
			case "--ipsw": o.ipsw = path(try value("--ipsw"))
			case "--disk-gb": o.diskGB = Int(try value("--disk-gb")) ?? 0
			case "--subnet": o.subnet = Int(try value("--subnet")) ?? -1
			case "--print-scripts": printScripts = true
			default: throw BayError("unknown option \(args[i])\n\(usage)")
			}
			i += 1
		}
		if xcode && o.xcode != nil { throw BayError("pass --xcode or --xcode-xip, not both") }
		guard o.diskGB >= 40 else { throw BayError("--disk-gb must be at least 40") }
		guard (0...255).contains(o.subnet) else { throw BayError("--subnet must be 0...255") }
		let wantsXcode = xcode || o.xcode != nil
		o.runtime = runtime == "none" ? nil : (runtime ?? (wantsXcode ? "iOS" : nil))
		if o.runtime != nil && !wantsXcode { throw BayError("--runtime needs --xcode or --xcode-xip") }
		if printScripts {
			out(
				"# provision, over SSH as cryo\n" + settingsCommands.joined(separator: "\n") + "\n\n# Xcode, over SSH as cryo\n"
					+ xcodeScript(runtime: o.runtime))
			return 0
		}
		if xcode { o.xcode = .app(try await hostXcode()) }
		let digest = try await build(o, paths: paths, out: out)
		out(
			"""
			next: freeze the capsules on it and switch to it (stop the bay first: Apple allows 2 VMs per Mac)
			  cryo image use \(digest)

			""")
		return 0
	}
}

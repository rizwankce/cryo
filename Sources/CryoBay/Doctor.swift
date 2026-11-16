import CryoAPI
import Foundation
import IOKit

/// Host checks for `cryo doctor` (docs/spec/setup.md "cryo doctor"). Facts are
/// read once without root; `HostDoctor.checks` turns them into results, and `--fix` runs the
/// `HostFix` of each failing check that has one. `--fix` only changes safe, reversible settings: it
/// never touches FileVault or the auto-login password, and never writes `/etc/kcpassword`.
public struct HostFacts: Sendable {
	public var osVersion: OperatingSystemVersion
	public var arm64: Bool
	/// Free bytes on the volume that holds `~/.cryo` (for important use, i.e. purgeable counts).
	public var freeBytes: Int64?
	public var memoryBytes: UInt64
	/// The running binary, symlinks resolved.
	public var executable: String
	public var home: String
	/// `~/.cryo/.metadata_never_index` exists.
	public var spotlightExcluded: Bool
	/// `pmset -g` settings for the current power source, e.g. `sleep: 0`. `autorestart` is missing
	/// where the hardware can't do it (VMs).
	public var pmset: [String: Int]
	/// `com.apple.SoftwareUpdate` values for `HostDoctor.updateKeys`; nil when unset.
	public var softwareUpdate: [String: String]
	public var pfHelperInstalled: Bool
	public var user: String
	/// Owner of `/dev/console`: the logged-in console user, `root` at the login window.
	public var consoleOwner: String?
	/// From the console session in `IOConsoleUsers`; nil when no session is on the console.
	public var screenLocked: Bool?
	public var autoLoginUser: String?
	public var kcpasswordExists: Bool
	/// `fdesetup status`, e.g. `FileVault is Off.`
	public var fileVault: String
	/// Capsule-subnet (10.77/16) addresses bootpd bound to something other than a capsule's own .2.
	public var capsuleDHCPBindings: [String]

	public init(
		osVersion: OperatingSystemVersion, arm64: Bool, freeBytes: Int64?, memoryBytes: UInt64, executable: String,
		home: String, spotlightExcluded: Bool, pmset: [String: Int], softwareUpdate: [String: String],
		pfHelperInstalled: Bool, user: String, consoleOwner: String?, screenLocked: Bool?,
		autoLoginUser: String?, kcpasswordExists: Bool, fileVault: String, capsuleDHCPBindings: [String] = []
	) {
		self.osVersion = osVersion
		self.arm64 = arm64
		self.freeBytes = freeBytes
		self.memoryBytes = memoryBytes
		self.executable = executable
		self.home = home
		self.spotlightExcluded = spotlightExcluded
		self.pmset = pmset
		self.softwareUpdate = softwareUpdate
		self.pfHelperInstalled = pfHelperInstalled
		self.user = user
		self.consoleOwner = consoleOwner
		self.screenLocked = screenLocked
		self.autoLoginUser = autoLoginUser
		self.kcpasswordExists = kcpasswordExists
		self.fileVault = fileVault
		self.capsuleDHCPBindings = capsuleDHCPBindings
	}

	/// Reads the facts from this Mac. Needs no root; takes ~0.2 s (a few `pmset`/`defaults` runs).
	public static func gather(paths: BayPaths) async -> HostFacts {
		let fm = FileManager.default
		var volume = paths.root
		while !fm.fileExists(atPath: volume.path), volume.path != "/" { volume = volume.deletingLastPathComponent() }
		let free = (try? volume.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]))?
			.volumeAvailableCapacityForImportantUsage
		let exe = Bundle.main.executableURL?.resolvingSymlinksInPath().path ?? CommandLine.arguments[0]

		var updates: [String: String] = [:]
		for key in HostDoctor.updateKeys {
			let r = await runProcess("/usr/bin/defaults", ["read", HostDoctor.softwareUpdatePlist, key])
			if r.status == 0 { updates[key] = r.out.trimmingCharacters(in: .whitespacesAndNewlines) }
		}
		let autoLogin = await runProcess("/usr/bin/defaults", ["read", "/Library/Preferences/com.apple.loginwindow", "autoLoginUser"])
		let root = IORegistryGetRootEntry(kIOMainPortDefault)
		let consoleUsers =
			IORegistryEntryCreateCFProperty(root, "IOConsoleUsers" as CFString, kCFAllocatorDefault, 0)?
			.takeRetainedValue() as? [[String: Any]]
		IOObjectRelease(root)

		return HostFacts(
			osVersion: ProcessInfo.processInfo.operatingSystemVersion,
			arm64: sysctlInt("hw.optional.arm64") == 1,
			freeBytes: free,
			memoryBytes: ProcessInfo.processInfo.physicalMemory,
			executable: exe,
			home: fm.homeDirectoryForCurrentUser.path,
			spotlightExcluded: fm.fileExists(atPath: paths.root.appending(path: ".metadata_never_index").path),
			pmset: HostDoctor.parsePmset(await runProcess("/usr/bin/pmset", ["-g"]).out),
			softwareUpdate: updates,
			pfHelperInstalled: fm.fileExists(atPath: BayInstall.helperPlist),
			user: NSUserName(),
			consoleOwner: (try? fm.attributesOfItem(atPath: "/dev/console"))?[.ownerAccountName] as? String,
			screenLocked: HostDoctor.consoleScreenLocked(consoleUsers ?? []),
			autoLoginUser: autoLogin.status == 0 ? autoLogin.out.trimmingCharacters(in: .whitespacesAndNewlines) : nil,
			kcpasswordExists: fm.fileExists(atPath: "/etc/kcpassword"),
			fileVault: await runProcess("/usr/bin/fdesetup", ["status"]).out.trimmingCharacters(in: .whitespacesAndNewlines),
			capsuleDHCPBindings: HostFacts.capsuleBindings(
				(try? String(contentsOfFile: HostFacts.dhcpLeases, encoding: .utf8)) ?? "",
				capsuleMACs: ((try? fm.contentsOfDirectory(atPath: paths.capsules.path)) ?? []).compactMap { name in
					guard let n = Int(name) else { return nil }
					return try? String(contentsOf: paths.capsule(n).mac, encoding: .utf8)
				}))
	}

	public static let dhcpLeases = DHCPLeases.path

	/// 10.77.0.0/16 addresses in bootpd's lease file that would block a capsule's first boot from
	/// getting its .2 (the freeze then pins it statically): any binding except a capsule's own MAC
	/// on a .2.
	public static func capsuleBindings(_ leases: String, capsuleMACs: [String] = []) -> [String] {
		let own = Set(capsuleMACs.map { DHCPLeases.octets($0.trimmingCharacters(in: .whitespacesAndNewlines)) })
		return DHCPLeases.parse(leases).filter { b in
			b.ip.hasPrefix("10.77.") && !(b.ip.hasSuffix(".2") && own.contains(b.mac))
		}.map(\.ip)
	}

	static func sysctlInt(_ name: String) -> Int {
		var v: Int32 = 0
		var size = MemoryLayout<Int32>.size
		return sysctlbyname(name, &v, &size, nil, 0) == 0 ? Int(v) : 0
	}
}

/// What `cryo doctor --fix` may change. Each runs as the user; `sudo` prompts where needed.
public enum HostFix: Sendable, Equatable {
	/// Create `~/.cryo` and its `.metadata_never_index` marker (no sudo).
	case spotlight
	/// `sudo pmset -a …`: sleep and display sleep off, `autorestart 1` where the hardware has it.
	case power(autorestart: Bool)
	/// `sudo defaults write /Library/Preferences/com.apple.SoftwareUpdate …` for each update key.
	case updates

	/// The commands this fix runs (`.spotlight` runs none: it is `BayPaths.prepare()`).
	public var commands: [[String]] {
		switch self {
		case .spotlight: return []
		case .power(let autorestart):
			return [["/usr/bin/sudo", "/usr/bin/pmset", "-a", "sleep", "0", "displaysleep", "0"] + (autorestart ? ["autorestart", "1"] : [])]
		case .updates:
			return HostDoctor.updateKeys.map {
				["/usr/bin/sudo", "/usr/bin/defaults", "write", HostDoctor.softwareUpdatePlist, $0, "-bool", "false"]
			}
		}
	}
}

public struct HostCheck: Sendable, Equatable {
	public var result: DoctorCheck
	/// What `--fix` does about a failure; nil when it only reports or guides.
	public var fix: HostFix?
	/// A failure keeps the bay from thawing (docs/spec/setup.md "Which checks block thawing"): a
	/// thaw now would fail or the host can't run the capsules. The others are reported only.
	public var gates = false
}

public enum HostDoctor {
	public static let minFreeGB = 150
	/// RAM left to macOS and the bay next to the capsules.
	public static let hostReserveGB = 4
	/// Per-capsule RAM assumed before an image is set (the images so far use 8 GB).
	public static let defaultCapsuleMemoryGB = 8
	static let softwareUpdatePlist = "/Library/Preferences/com.apple.SoftwareUpdate"
	/// Downloading and installing macOS updates. Checking stays on so the owner sees updates; Security
	/// Responses / system data files (`CriticalUpdateInstall`, `ConfigDataInstall`) are left alone.
	public static let updateKeys = ["AutomaticDownload", "AutomaticallyInstallMacOSUpdates"]
	/// Folders TCC guards; vmnet refuses a binary inside them.
	static let protectedFolders = ["Documents", "Desktop", "Downloads"]

	/// The TCC-guarded folder under `home` that holds `path` (e.g. `Documents`), or nil. The one rule
	/// for "vmnet would refuse this binary", shared by `doctor` and `cryo bay install`.
	public static func protectedFolder(holding path: String, home: String) -> String? {
		let home = home.hasSuffix("/") ? String(home.dropLast()) : home
		return protectedFolders.first { path.hasPrefix(home + "/" + $0 + "/") }
	}

	public static func checks(_ f: HostFacts, capsules: Int, capsuleMemoryGB: Int) -> [HostCheck] {
		var out: [HostCheck] = []
		func add(_ name: String, _ ok: Bool, _ hint: @autoclosure () -> String, fix: HostFix? = nil, gates: Bool = false) {
			out.append(HostCheck(result: DoctorCheck(check: name, ok: ok, fix: ok ? nil : hint()), fix: ok ? nil : fix, gates: gates))
		}
		let v = f.osVersion
		add(
			"macOS 27.x (\(v.majorVersion).\(v.minorVersion).\(v.patchVersion))", v.majorVersion == 27, "Cryo supports macOS 27 hosts only",
			gates: true)
		add("Apple silicon", f.arm64, "Cryo needs an Apple silicon Mac", gates: true)
		let freeGB = Int((f.freeBytes ?? 0) / 1_000_000_000)
		add("≥\(minFreeGB) GB free (\(freeGB) GB)", freeGB >= minFreeGB, "free disk space on the volume holding ~/.cryo")
		let ramGB = Int(f.memoryBytes >> 30)
		let needGB = capsules * capsuleMemoryGB + hostReserveGB
		add(
			"RAM for \(capsules) × \(capsuleMemoryGB) GB capsules + host (\(ramGB) of \(needGB) GB)", ramGB >= needGB,
			"use a Mac with more RAM, or set capsules = 1 in config.toml", gates: true)

		let exe = f.executable
		let badFolder = protectedFolder(holding: exe, home: f.home)
		add(
			"binary not under ~/\(badFolder ?? "Documents") (\(exe))", badFolder == nil,
			"vmnet refuses it there; install to ~/.cryo/bin (scripts/build-bay.sh)", gates: true)
		add("~/.cryo excluded from Spotlight", f.spotlightExcluded, "create ~/.cryo/.metadata_never_index", fix: .spotlight)

		let hasAutorestart = f.pmset["autorestart"] != nil
		let powerOK = f.pmset["sleep"] == 0 && f.pmset["displaysleep"] == 0 && (!hasAutorestart || f.pmset["autorestart"] == 1)
		add(
			"sleep and display sleep off, " + (hasAutorestart ? "pmset autorestart 1" : "autorestart (not on this hardware)"),
			powerOK, "sudo pmset -a sleep 0 displaysleep 0" + (hasAutorestart ? " autorestart 1" : ""),
			fix: .power(autorestart: hasAutorestart))
		// `defaults read` prints a bool as 0/1; unset means macOS's default, which may be on.
		let updatesOn = updateKeys.filter { f.softwareUpdate[$0] != "0" }
		add(
			"automatic macOS updates off", updatesOn.isEmpty,
			"turn off \(updatesOn.joined(separator: ", ")) (System Settings > General > Software Update > Automatic updates)",
			fix: .updates)
		add("pf root helper installed (\(BayInstall.helperPlist))", f.pfHelperInstalled, "cryo bay install")
		// A binding of a capsule's .2 to another MAC moves that guest to .3 and its refills fail.
		add(
			"no DHCP bindings on capsule subnets", f.capsuleDHCPBindings.isEmpty,
			"stale \(f.capsuleDHCPBindings.joined(separator: ", ")) in \(HostFacts.dhcpLeases); "
				+ (f.pfHelperInstalled ? "sudo launchctl kickstart -k system/\(BayInstall.helperLabel)" : "cryo bay install")
				+ " clears them (the root helper also does at every boot)")

		add(
			"console owned by \(f.user)", f.consoleOwner == f.user,
			f.consoleOwner == nil
				? "can't read the owner of /dev/console"
				: "the console belongs to \(f.consoleOwner!); log in as \(f.user) at the Mac (auto-login)",
			gates: true)
		add(
			"screen unlocked", f.screenLocked == false,
			f.screenLocked == nil ? "no session on the console; log in as \(f.user)" : "unlock the screen; turn off screen lock",
			gates: true)
		let autoLoginOK = f.autoLoginUser == f.user && f.kcpasswordExists
		add(
			"auto-login set to \(f.user)", autoLoginOK,
			"System Settings > Users & Groups > Automatically log in as \(f.user)"
				+ (f.autoLoginUser == f.user ? " (the saved password is missing)" : f.autoLoginUser.map { " (now: \($0))" } ?? ""))
		add(
			"FileVault off", f.fileVault.hasPrefix("FileVault is Off"),
			"\(f.fileVault) Turn it off in System Settings > Privacy & Security > FileVault; decrypting takes hours and is your call")
		return out
	}

	/// The failing checks that keep the bay from thawing; empty when it may thaw. `ignore` is
	/// `ignore_doctor = true` in config.toml: thaw anyway (a dev Mac), the checks still report.
	public static func blocking(_ checks: [HostCheck], ignore: Bool) -> [DoctorCheck] {
		ignore ? [] : checks.filter { $0.gates && !$0.result.ok }.map(\.result)
	}

	/// `pmset -g` lines like ` sleep  0 (sleep prevented by …)` → `["sleep": 0]`. The first number is
	/// the setting; the parenthesis is only what currently holds it off.
	public static func parsePmset(_ text: String) -> [String: Int] {
		var out: [String: Int] = [:]
		for line in text.split(separator: "\n") where line.hasPrefix(" ") {
			let words = line.split(separator: " ")
			// Keys can have spaces ("Sleep On Power Button 1"); the value is the first number after them.
			guard let i = words.firstIndex(where: { Int($0) != nil }), i > 0 else { continue }
			out[words[..<i].joined(separator: " ")] = Int(words[i])
		}
		return out
	}

	/// The console session's lock state from the registry root's `IOConsoleUsers` (what `ioreg -n
	/// Root -d1` shows). macOS sets `CGSSessionScreenIsLocked` only while locked. Nil when no
	/// session is on the console.
	public static func consoleScreenLocked(_ users: [[String: Any]]) -> Bool? {
		guard let session = users.first(where: { $0["kCGSSessionOnConsoleKey"] as? Bool == true }) else { return nil }
		return session["CGSSessionScreenIsLocked"] as? Bool ?? false
	}
}

extension HostDoctor {
	/// The host checks as the CLI sees them: capsule count and RAM from this Mac's config and image.
	/// Blocking, for the synchronous CLI (the bay runs `HostFacts.gather` itself).
	public static func localChecks(paths: BayPaths = .standard()) -> [HostCheck] {
		let config = (try? BayConfig.load(paths.config)) ?? BayConfig()
		let memoryGB = config.image.flatMap { try? BayJSON.read(ImageInfo.self, from: paths.image($0).info).memoryGB }
		let box = FactsBox()
		let done = DispatchSemaphore(value: 0)
		Task.detached {
			box.facts = await HostFacts.gather(paths: paths)
			done.signal()
		}
		done.wait()
		return checks(box.facts!, capsules: config.capsules, capsuleMemoryGB: memoryGB ?? defaultCapsuleMemoryGB)
	}

	/// Runs one fix with the terminal attached, so `sudo` can ask for the password. Prints each
	/// command first. Returns false when a command fails.
	public static func apply(_ fix: HostFix, paths: BayPaths = .standard(), say: (String) -> Void) -> Bool {
		if fix == .spotlight {
			say("  creating \(paths.root.path) and its .metadata_never_index")
			do { try paths.prepare() } catch {
				say("  failed: \(error)")
				return false
			}
			return true
		}
		for command in fix.commands {
			say("  running: " + command.joined(separator: " "))
			let p = Process()
			p.executableURL = URL(filePath: command[0])
			p.arguments = Array(command.dropFirst())
			do { try p.run() } catch {
				say("  failed: \(error)")
				return false
			}
			p.waitUntilExit()
			guard p.terminationStatus == 0 else {
				say("  failed: exit \(p.terminationStatus)")
				return false
			}
		}
		return true
	}
}

private final class FactsBox: @unchecked Sendable {
	var facts: HostFacts?
}

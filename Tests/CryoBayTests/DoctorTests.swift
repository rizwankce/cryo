import CryoAPI
import Foundation
import Testing

@testable import CryoBay

@Suite("Host doctor")
struct DoctorTests {
	/// A host that passes every check: a 32 GB mini on 27.2 set up as setup.md says.
	static let good = HostFacts(
		osVersion: OperatingSystemVersion(majorVersion: 27, minorVersion: 2, patchVersion: 0), arm64: true,
		freeBytes: 400_000_000_000, memoryBytes: 32 << 30, executable: "/Users/ci/.cryo/bin/cryo", home: "/Users/ci",
		spotlightExcluded: true, pmset: ["sleep": 0, "displaysleep": 0, "autorestart": 1],
		softwareUpdate: ["AutomaticDownload": "0", "AutomaticallyInstallMacOSUpdates": "0"], pfHelperInstalled: true,
		user: "ci", consoleOwner: "ci", screenLocked: false, autoLoginUser: "ci", kcpasswordExists: true,
		fileVault: "FileVault is Off.")

	func failing(_ f: HostFacts, capsules: Int = 2, memoryGB: Int = 8) -> [HostCheck] {
		HostDoctor.checks(f, capsules: capsules, capsuleMemoryGB: memoryGB).filter { !$0.result.ok }
	}

	@Test func goodHostPasses() {
		#expect(failing(Self.good).isEmpty)
	}

	@Test func eachProblemFailsItsOwnCheckWithTheRightFix() {
		func only(_ change: (inout HostFacts) -> Void) -> HostCheck? {
			var f = Self.good
			change(&f)
			let bad = failing(f)
			return bad.count == 1 ? bad[0] : nil
		}
		#expect(only { $0.osVersion.majorVersion = 26 }?.fix == nil)
		#expect(only { $0.arm64 = false }?.result.check == "Apple silicon")
		#expect(only { $0.freeBytes = 149_000_000_000 } != nil)
		#expect(only { $0.executable = "/Users/ci/Documents/cryo/cryo" }?.result.check.contains("~/Documents") == true)
		#expect(only { $0.executable = "/Users/ci/Desktop/cryo" }?.result.check.contains("~/Desktop") == true)
		#expect(only { $0.spotlightExcluded = false }?.fix == .spotlight)
		// Display sleep alone is enough to fail; autorestart 0 too.
		#expect(only { $0.pmset["displaysleep"] = 10 }?.fix == .power(autorestart: true))
		#expect(only { $0.pmset["autorestart"] = 0 }?.fix == .power(autorestart: true))
		// One update key unset counts as on (macOS's default may be on).
		#expect(only { $0.softwareUpdate["AutomaticallyInstallMacOSUpdates"] = nil }?.fix == .updates)
		#expect(only { $0.softwareUpdate["AutomaticDownload"] = "1" }?.fix == .updates)
		// Reported or guided only: --fix never touches these.
		#expect(only { $0.pfHelperInstalled = false }?.result.fix == "cryo bay install")
		#expect(only { $0.consoleOwner = "root" }?.fix == nil)
		#expect(only { $0.screenLocked = true }?.fix == nil)
		#expect(only { $0.screenLocked = nil }?.fix == nil)
		#expect(only { $0.autoLoginUser = "admin" }?.result.fix?.contains("now: admin") == true)
		#expect(only { $0.kcpasswordExists = false }?.fix == nil)
		#expect(only { $0.fileVault = "FileVault is On." }?.fix == nil)
		#expect(only { $0.capsuleDHCPBindings = ["10.77.0.2"] }?.result.fix?.contains("kickstart -k system/dev.rizwan.cryo.pf") == true)
		#expect(only { $0.fileVault = "Decryption in progress: Percent completed = 12" } != nil)
	}

	/// Only 10.77/16 bindings count: a stale one moved capsule 0 to .3.
	@Test func capsuleBindingsComeFromTheLeaseFile() {
		let leases = """
			{
				name=CryosVilMachine
				ip_address=10.77.0.2
				hw_address=1,12:ab:cd:10:20:32
			}
			{
				name=Other
				ip_address=192.168.64.2
			}
			{
				ip_address=10.77.1.3
			}
			"""
		#expect(HostFacts.capsuleBindings(leases) == ["10.77.0.2", "10.77.1.3"])
		#expect(HostFacts.capsuleBindings("").isEmpty)
		// A capsule's own MAC on its .2 is fine (written by the freeze's first boot), zeros or not.
		#expect(HostFacts.capsuleBindings(leases, capsuleMACs: ["12:ab:cd:10:20:32\n"]) == ["10.77.1.3"])
		#expect(HostFacts.capsuleBindings("{\n\tip_address=10.77.0.2\n\thw_address=1,12:ab:cd:10:3:33\n}", capsuleMACs: ["12:ab:cd:10:03:33"]).isEmpty)
	}

	/// The thaw gate (setup.md "Which checks block thawing"): what makes a thaw fail now blocks it;
	/// what only matters after a reboot or over time is reported.
	@Test func onlyChecksThatBreakAThawBlockIt() {
		func blocking(_ change: (inout HostFacts) -> Void) -> [String] {
			var f = Self.good
			change(&f)
			let checks = HostDoctor.checks(f, capsules: 2, capsuleMemoryGB: 8)
			#expect(checks.contains { !$0.result.ok }, "the change should fail some check")
			return HostDoctor.blocking(checks, ignore: false).map(\.check)
		}
		#expect(HostDoctor.blocking(HostDoctor.checks(Self.good, capsules: 2, capsuleMemoryGB: 8), ignore: false).isEmpty)
		// Block: the capsules can't run, or a restore fails right now.
		#expect(blocking { $0.osVersion.majorVersion = 26 }.first?.hasPrefix("macOS 27.x") == true)
		#expect(blocking { $0.arm64 = false } == ["Apple silicon"])
		#expect(blocking { $0.memoryBytes = 16 << 30 }.first?.hasPrefix("RAM for 2") == true)
		#expect(blocking { $0.executable = "/Users/ci/Downloads/cryo" }.first?.contains("~/Downloads") == true)
		#expect(blocking { $0.consoleOwner = "root" } == ["console owned by ci"])
		#expect(blocking { $0.screenLocked = true } == ["screen unlocked"])
		#expect(blocking { $0.screenLocked = nil } == ["screen unlocked"])
		// Report only: the bay thaws, `doctor` still says failing.
		#expect(blocking { $0.freeBytes = 10_000_000_000 }.isEmpty)
		#expect(blocking { $0.spotlightExcluded = false }.isEmpty)
		#expect(blocking { $0.pmset["sleep"] = 10 }.isEmpty)
		#expect(blocking { $0.softwareUpdate["AutomaticDownload"] = "1" }.isEmpty)
		#expect(blocking { $0.pfHelperInstalled = false }.isEmpty)
		#expect(blocking { $0.autoLoginUser = nil }.isEmpty)
		#expect(blocking { $0.kcpasswordExists = false }.isEmpty)
		#expect(blocking { $0.fileVault = "FileVault is On." }.isEmpty)
	}

	@Test func ignoreDoctorOpensTheGateButKeepsTheReport() {
		var f = Self.good
		f.consoleOwner = "root"
		f.screenLocked = nil
		f.arm64 = false
		let checks = HostDoctor.checks(f, capsules: 2, capsuleMemoryGB: 8)
		#expect(HostDoctor.blocking(checks, ignore: false).map(\.check) == ["Apple silicon", "console owned by ci", "screen unlocked"])
		#expect(HostDoctor.blocking(checks, ignore: true).isEmpty)
		#expect(checks.filter { !$0.result.ok }.count == 3)
	}

	@Test func binaryElsewhereUnderHomeIsFine() {
		var f = Self.good
		f.executable = "/Users/ci/DocumentsArchive/cryo"  // a prefix of ~/Documents, not inside it
		#expect(failing(f).isEmpty)
	}

	/// The one rule doctor and `cryo bay install` share for where vmnet refuses the binary.
	@Test func protectedFolderRule() {
		#expect(HostDoctor.protectedFolder(holding: "/Users/ci/Documents/cryo/cryo", home: "/Users/ci") == "Documents")
		#expect(HostDoctor.protectedFolder(holding: "/Users/ci/Desktop/cryo", home: "/Users/ci/") == "Desktop")
		#expect(HostDoctor.protectedFolder(holding: "/Users/ci/Downloads/x/cryo", home: "/Users/ci") == "Downloads")
		#expect(HostDoctor.protectedFolder(holding: "/Users/ci/.cryo/bin/cryo", home: "/Users/ci") == nil)
		#expect(HostDoctor.protectedFolder(holding: "/Users/ci/DocumentsArchive/cryo", home: "/Users/ci") == nil)
		// Another user's Documents isn't this user's TCC folder.
		#expect(HostDoctor.protectedFolder(holding: "/Users/other/Documents/cryo", home: "/Users/ci") == nil)
	}

	@Test func ramNeedsTwoCapsulesPlusHost() {
		var f = Self.good
		f.memoryBytes = 16 << 30
		#expect(failing(f, memoryGB: 8).count == 1)  // 2 × 8 + 4 > 16
		#expect(failing(f, memoryGB: 6).isEmpty)  // 2 × 6 + 4 = 16
		#expect(failing(f, capsules: 1, memoryGB: 8).isEmpty)
	}

	@Test func autorestartOptionalWhereTheHardwareLacksIt() {
		var f = Self.good
		f.pmset = ["sleep": 0, "displaysleep": 0]  // a VM: no autorestart capability
		#expect(failing(f).isEmpty)
		f.pmset["sleep"] = 1
		#expect(failing(f).map(\.fix) == [.power(autorestart: false)])
		#expect(HostFix.power(autorestart: false).commands == [["/usr/bin/sudo", "/usr/bin/pmset", "-a", "sleep", "0", "displaysleep", "0"]])
	}

	@Test func fixesNeverTouchFileVaultOrAutoLogin() {
		let all = [HostFix.spotlight, .power(autorestart: true), .updates].flatMap(\.commands).flatMap { $0 }
		#expect(!all.contains { $0.contains("fdesetup") || $0.contains("kcpassword") || $0.contains("sysadminctl") || $0.contains("loginwindow") })
	}

	@Test func parsesPmsetSettingNotTheHold() {
		let text = """
			System-wide power settings:
			Currently in use:
			 powernap             1
			 sleep                10 (sleep prevented by caffeinate, powerd)
			 Sleep On Power Button 1
			 autorestart          0
			 displaysleep         0 (display sleep prevented by caffeinate)
			"""
		let p = HostDoctor.parsePmset(text)
		#expect(p["sleep"] == 10)
		#expect(p["displaysleep"] == 0)
		#expect(p["autorestart"] == 0)
		#expect(p["Sleep On Power Button"] == 1)
		#expect(p["Currently in use:"] == nil)
	}

	@Test func screenLockFromConsoleUsers() {
		let other: [String: Any] = ["kCGSSessionOnConsoleKey": false, "CGSSessionScreenIsLocked": true]
		#expect(HostDoctor.consoleScreenLocked([other, ["kCGSSessionOnConsoleKey": true]]) == false)
		#expect(HostDoctor.consoleScreenLocked([["kCGSSessionOnConsoleKey": true, "CGSSessionScreenIsLocked": true]]) == true)
		#expect(HostDoctor.consoleScreenLocked([other]) == nil)
		#expect(HostDoctor.consoleScreenLocked([]) == nil)
	}
}

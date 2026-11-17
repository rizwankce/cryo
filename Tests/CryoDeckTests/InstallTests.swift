import CryoDeck
import Foundation
import Testing

@Suite struct DeckInstallTests {
	private let paths = DeckPaths(root: URL(filePath: "/Users/x/.cryo", directoryHint: .isDirectory))

	@Test func namesAndLocations() {
		#expect(DeckInstall.agentLabel == "dev.rizwan.cryo.deck")
		#expect(DeckInstall.unitName == "cryo-deck.service")
		#expect(DeckInstall.agentPlist(home: "/Users/x") == "/Users/x/Library/LaunchAgents/dev.rizwan.cryo.deck.plist")
		#expect(DeckInstall.unitPath(home: "/home/x") == "/home/x/.config/systemd/user/cryo-deck.service")
	}

	private func plist(_ binary: String = "/usr/local/bin/cryo") throws -> [String: Any] {
		let data = try DeckInstall.launchAgentData(binary: binary, paths: paths)
		#expect(String(decoding: data, as: UTF8.self).hasPrefix("<?xml"))
		return try #require(try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
	}

	@Test func launchAgentRunsDeckStartAtLoad() throws {
		let p = try plist()
		#expect(p["Label"] as? String == "dev.rizwan.cryo.deck")
		#expect(p["ProgramArguments"] as? [String] == ["/usr/local/bin/cryo", "deck", "start"])
		#expect(p["RunAtLoad"] as? Bool == true)
		#expect(p["ThrottleInterval"] as? Int == 30)
	}

	@Test func launchAgentPointsAtTheRootAndTheLog() throws {
		let p = try plist()
		#expect((p["EnvironmentVariables"] as? [String: String])?["CRYO_HOME"] == "/Users/x/.cryo")
		#expect(p["StandardOutPath"] as? String == "/Users/x/.cryo/deck.log")
		#expect(p["StandardErrorPath"] as? String == "/Users/x/.cryo/deck.log")
	}

	@Test func launchAgentRestartsAfterACrashButNotACleanStop() throws {
		let p = try plist()
		#expect((p["KeepAlive"] as? [String: Bool])?["SuccessfulExit"] == false)
	}

	@Test func launchAgentKeepsABinaryPathWithSpacesInOneArgument() throws {
		let p = try plist("/Applications/My Tools/cryo")
		#expect((p["ProgramArguments"] as? [String])?.first == "/Applications/My Tools/cryo")
		#expect((p["ProgramArguments"] as? [String])?.count == 3)
	}

	@Test func systemdUnitHasTheThreeSections() {
		let unit = DeckInstall.systemdUnit(binary: "/usr/local/bin/cryo", paths: paths)
		let u = unit.range(of: "[Unit]")
		let s = unit.range(of: "[Service]")
		let i = unit.range(of: "[Install]")
		#expect(u != nil && s != nil && i != nil)
		#expect(u!.lowerBound < s!.lowerBound && s!.lowerBound < i!.lowerBound)
		#expect(unit.hasSuffix("\n"))
		#expect(unit.contains("Description=cryo deck"))
		#expect(unit.contains("After=network-online.target"))
		#expect(unit.contains("Wants=network-online.target"))
		#expect(unit.contains("WantedBy=default.target"))
	}

	@Test func systemdUnitRunsDeckStartWithTheRootAndLog() {
		let unit = DeckInstall.systemdUnit(binary: "/usr/local/bin/cryo", paths: paths)
		#expect(unit.contains("ExecStart=\"/usr/local/bin/cryo\" deck start\n"))
		#expect(unit.contains("Environment=\"CRYO_HOME=/Users/x/.cryo\"\n"))
		#expect(unit.contains("StandardOutput=append:/Users/x/.cryo/deck.log\n"))
		#expect(unit.contains("StandardError=append:/Users/x/.cryo/deck.log\n"))
		#expect(unit.contains("Restart=on-failure\n"))
		#expect(unit.contains("RestartSec=5\n"))
	}

	@Test func systemdUnitQuotesPathsWithSpacesAndQuotes() {
		let unit = DeckInstall.systemdUnit(binary: #"/opt/my cryo/"bin"/cryo"#, paths: paths)
		#expect(unit.contains(#"ExecStart="/opt/my cryo/\"bin\"/cryo" deck start"#))
	}
}

import Foundation
import Testing

@testable import CryoBay

@Suite struct InstallTests {
	@Test func agentRunsTheBayFromThisBinaryAndHome() throws {
		let paths = BayPaths(root: URL(filePath: "/tmp/side bay", directoryHint: .isDirectory))
		let data = try BayInstall.agentPlistData(binary: "/Users/me/.cryo/bin/cryo", paths: paths)
		let p = try #require(try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
		#expect(p["Label"] as? String == "dev.cryo.bay")
		#expect(p["ProgramArguments"] as? [String] == ["/Users/me/.cryo/bin/cryo", "bay", "start"])
		#expect((p["EnvironmentVariables"] as? [String: String])?["CRYO_HOME"] == "/tmp/side bay")
		#expect(p["RunAtLoad"] as? Bool == true)
	}

	@Test func helperLoadsTheRootOwnedRulesIntoTheAnchor() throws {
		let data = try BayInstall.helperPlistData()
		let p = try #require(try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
		#expect(p["Label"] as? String == "dev.cryo.pf")
		let cmd = try #require((p["ProgramArguments"] as? [String])?.last)
		#expect(cmd.contains("-a com.apple/cryo -f '/Library/Application Support/Cryo/cryo.pf'"))
		#expect(BayInstall.pfRules.contains("block in quick from $capsules to $private"))
		#expect(cmd.hasPrefix(BayInstall.clearCapsuleDHCP + ";"))
	}

	/// DNS is allowed to the gateways only (10.77.N.1, what vmnet listens on), not to port 53 on
	/// another capsule's guest.
	@Test func dnsRuleNamesOnlyTheGateways() throws {
		let gateways = BayInstall.pfGateways()
		#expect(gateways.count == 256 && gateways.first == "10.77.0.1" && gateways.last == "10.77.255.1")
		#expect(gateways.allSatisfy { $0.hasSuffix(".1") })
		#expect(gateways.contains(CapsuleNetwork(subnet: 9).gateway))
		let rules = BayInstall.pfRules
		#expect(rules.contains("pass in quick proto { udp, tcp } from $capsules to <cryo_gateways> port 53"))
		#expect(!rules.contains("to $capsules port 53") && !rules.contains("$slots"))
		// Every gateway in the table, none twice.
		let table = rules.components(separatedBy: "table <cryo_gateways> const {")[1].components(separatedBy: "}")[0]
		let listed = table.split(whereSeparator: { ", \\\n\t".contains($0) }).map(String.init)
		#expect(listed == gateways)
	}

	/// `pfctl -n` parses without loading (no root needed), so a syntax error can't reach the helper.
	@Test func pfRulesParse() async throws {
		let dir = FileManager.default.temporaryDirectory.appending(path: "cryo-pf-\(UUID().uuidString)", directoryHint: .isDirectory)
		try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
		defer { try? FileManager.default.removeItem(at: dir) }
		let f = dir.appending(path: "cryo.pf")
		try BayInstall.pfRules.write(to: f, atomically: true, encoding: .utf8)
		let r = await runProcess("/sbin/pfctl", ["-a", BayInstall.pfAnchor, "-nvf", f.path])
		#expect(r.status == 0, "\(r.out)")
		#expect(r.out.contains("<cryo_gateways> port = 53"))
	}

	/// The helper's clean-up drops only capsule-subnet bindings.
	@Test func clearCapsuleDHCPKeepsOtherBindings() async throws {
		let dir = FileManager.default.temporaryDirectory.appending(path: "cryo-dhcp-\(UUID().uuidString)", directoryHint: .isDirectory)
		try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
		defer { try? FileManager.default.removeItem(at: dir) }
		let f = dir.appending(path: "leases")
		try "{\n\tip_address=10.77.0.2\n\thw_address=1,aa\n}\n{\n\tip_address=192.168.64.2\n}\n{\n\tip_address=10.77.1.3\n}\n"
			.write(to: f, atomically: true, encoding: .utf8)
		let perl = BayInstall.clearCapsuleDHCP.split(separator: "; ", maxSplits: 1)[1]
			.replacingOccurrences(of: HostFacts.dhcpLeases, with: f.path)
		#expect(await runProcess("/bin/sh", ["-c", perl]).status == 0)
		#expect(try String(contentsOf: f, encoding: .utf8) == "{\n\tip_address=192.168.64.2\n}\n")
	}

	@Test func prepareHomeKeepsAnExistingConfig() throws {
		let root = FileManager.default.temporaryDirectory.appending(path: "cryo-install-\(UUID().uuidString)", directoryHint: .isDirectory)
		defer { try? FileManager.default.removeItem(at: root) }
		let paths = BayPaths(root: root)
		#expect(try BayInstall.prepareHome(paths))
		#expect(FileManager.default.fileExists(atPath: root.appending(path: ".metadata_never_index").path))
		try "image = \"abc\"\n".write(to: paths.config, atomically: true, encoding: .utf8)
		#expect(try !BayInstall.prepareHome(paths))
		#expect(try BayConfig.load(paths.config).image == "abc")
	}
}

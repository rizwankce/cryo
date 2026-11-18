import Foundation
import Testing

@testable import CryoBay

@Suite struct InstallTests {
	@Test func agentRunsTheBayFromThisBinaryAndHome() throws {
		let paths = BayPaths(root: URL(filePath: "/tmp/side bay", directoryHint: .isDirectory))
		let data = try BayInstall.agentPlistData(binary: "/Users/me/.cryo/bin/cryo", paths: paths)
		let p = try #require(try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
		#expect(p["Label"] as? String == "dev.rizwan.cryo.bay")
		#expect(p["ProgramArguments"] as? [String] == ["/Users/me/.cryo/bin/cryo", "bay", "start"])
		#expect((p["EnvironmentVariables"] as? [String: String])?["CRYO_HOME"] == "/tmp/side bay")
		#expect(p["RunAtLoad"] as? Bool == true)
	}

	@Test func helperLoadsTheRootOwnedRulesIntoTheAnchor() throws {
		let data = try BayInstall.helperPlistData()
		let p = try #require(try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
		#expect(p["Label"] as? String == "dev.rizwan.cryo.pf")
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
		#expect(r.out.contains("block drop in quick on bridge100 inet6 all"))
		#expect(r.out.contains("block drop in quick on bridge199 inet6 all"))
	}

	/// IPv6 from any vmnet bridge is dropped: the IPv4 rules don't cover a guest reaching the host's
	/// link-local address (rizwankce/cryo#1).
	@Test func ipv6IsBlockedOnEveryVmnetBridge() {
		let bridges = BayInstall.pfBridges()
		#expect(bridges.count == 100 && bridges.first == "bridge100" && bridges.last == "bridge199")
		let rules = BayInstall.pfRules
		#expect(rules.contains("block in quick on $vmnet_bridges inet6 all"))
		let list = rules.components(separatedBy: "vmnet_bridges = \"{ \\\n")[1].components(separatedBy: "}")[0]
		#expect(list.split(whereSeparator: { ", \\\n\t".contains($0) }).map(String.init) == bridges)
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

	private func tempPaths() -> BayPaths {
		BayPaths(root: FileManager.default.temporaryDirectory.appending(path: "cryo-install-\(UUID().uuidString)", directoryHint: .isDirectory))
	}

	@Test func installListenWritesTheKeyToANewConfig() throws {
		let paths = tempPaths()
		defer { try? FileManager.default.removeItem(at: paths.root) }
		#expect(try BayInstall.prepareHome(paths, listen: ":7477"))
		#expect(try BayConfig.load(paths.config).listen == ":7477")
	}

	@Test func installListenSetsTheKeyAndKeepsOtherSettings() throws {
		let paths = tempPaths()
		defer { try? FileManager.default.removeItem(at: paths.root) }
		_ = try BayInstall.prepareHome(paths)
		try "image = \"abc\"\ncapsules = 1\nlisten = \":1111\"\n".write(to: paths.config, atomically: true, encoding: .utf8)
		#expect(try !BayInstall.prepareHome(paths, listen: "10.0.0.2:7477"))
		let c = try BayConfig.load(paths.config)
		#expect(c.listen == "10.0.0.2:7477")
		#expect(c.image == "abc")
		#expect(c.capsules == 1)
	}

	@Test func installWithoutListenKeepsAnExistingValue() throws {
		let paths = tempPaths()
		defer { try? FileManager.default.removeItem(at: paths.root) }
		_ = try BayInstall.prepareHome(paths, listen: ":7477")
		let before = try String(contentsOf: paths.config, encoding: .utf8)
		#expect(try !BayInstall.prepareHome(paths))
		#expect(try String(contentsOf: paths.config, encoding: .utf8) == before)
		#expect(try BayConfig.load(paths.config).listen == ":7477")
	}

	@Test func installArgumentsTakeOnlyAValidListen() throws {
		#expect(try BayInstall.parseInstallArgs([]) == nil)
		#expect(try BayInstall.parseInstallArgs(["--listen", ":7477"]) == ":7477")
		#expect(try BayInstall.parseInstallArgs(["--listen", "7477"]) == "7477")
		#expect(throws: BayError.self) { try BayInstall.parseInstallArgs(["--listen"]) }
		#expect(throws: BayError.self) { try BayInstall.parseInstallArgs(["--listen", "x:y"]) }
		#expect(throws: BayError.self) { try BayInstall.parseInstallArgs(["--bogus"]) }
	}
}

import CryoHTTP
import Foundation

/// `cryo bay install` / `cryo bay uninstall` (docs/spec/setup.md "Flow"): `~/.cryo` with its config,
/// the bay's LaunchAgent (starts at login) and the root helper that loads the pf anchor at
/// every boot. Everything that needs root goes through one `sudo` call.
public enum BayInstall {
	/// The bay's LaunchAgent, bootstrapped into the logged-in user's GUI session.
	public static let agentLabel = "dev.rizwan.cryo.bay"
	/// The root helper: a LaunchDaemon that loads the pf anchor at boot. `cryo doctor` checks this file.
	public static let helperLabel = "dev.rizwan.cryo.pf"
	public static let helperPlist = "/Library/LaunchDaemons/dev.rizwan.cryo.pf.plist"
	/// Root-owned copy of the rules the helper loads, so the user account can't change what root loads.
	public static let helperRules = "/Library/Application Support/Cryo/cryo.pf"
	static let helperLog = "/var/log/cryo-pf.log"
	public static let pfAnchor = "com.apple/cryo"

	/// The capsule fence (scripts/check-fence.sh tests it). Capsules live on
	/// vmnet networks inside 10.77.0.0/16. Loaded into Apple's anchor tree, which /etc/pf.conf
	/// already evaluates.
	static let pfRules = pfRulesText()

	/// Every capsule subnet's gateway, 10.77.N.1 (CapsuleNetwork.gateway): the host's side of the
	/// vmnet network, where vmnet's DNS proxy answers. Never a guest (.2).
	static func pfGateways() -> [String] { (0...255).map { CapsuleNetwork(subnet: $0).gateway } }

	/// The host-side interfaces vmnet creates for its networks, numbered from bridge100. macOS pf has no
	/// interface group for bridges, and the root helper loads the rules at boot before any exists, so
	/// the fence names a fixed range; pf applies a rule to an interface once it appears.
	static func pfBridges() -> [String] { (100...199).map { "bridge\($0)" } }

	/// Items as a pf list body, eight per line.
	static func pfList(_ items: [String]) -> String {
		stride(from: 0, to: items.count, by: 8).map { items[$0..<min($0 + 8, items.count)].joined(separator: ", ") }
			.joined(separator: ", \\\n\t")
	}

	static func pfRulesText() -> String {
		let gateways = pfList(pfGateways())
		let bridges = pfList(pfBridges())
		return """
			# Cryo capsule fence, installed by `cryo bay install`.
			capsules = "10.77.0.0/16"
			private = "{ 10.0.0.0/8, 172.16.0.0/12, 192.168.0.0/16, 169.254.0.0/16, 100.64.0.0/10 }"
			# vmnet's host-side bridges (capsules and any other vmnet VM on this Mac).
			vmnet_bridges = "{ \\
				\(bridges) }"
			# 10.77.N.1 for every N: the host on each capsule network (vmnet's DNS proxy).
			table <cryo_gateways> const { \\
				\(gateways) }

			# Guest -> a gateway: only DNS. Not port 53 on another capsule's guest, which "to $capsules"
			# allowed. DHCP is broadcast and not matched here.
			pass in quick proto { udp, tcp } from $capsules to <cryo_gateways> port 53
			# Guest -> anything private: the LAN, the host's own services, other capsules, other VM networks.
			block in quick from $capsules to $private
			# LAN machines routing in through the host can't reach a capsule. Only private sources: a broader
			# "from ! $capsules" also caught NAT'd internet replies and cut the guest's egress.
			block in quick from $private to $capsules
			# Capsules are IPv4 only. Without this a guest reaches the host's own services on the bridge's
			# fe80:: address, which the IPv4 rules above don't cover.
			block in quick on $vmnet_bridges inet6 all

			"""
	}

	public static func agentPlist(home: URL) -> URL {
		home.appending(path: "Library/LaunchAgents/\(agentLabel).plist")
	}

	static func agentPlistData(binary: String, paths: BayPaths) throws -> Data {
		let plist: [String: Any] = [
			"Label": agentLabel,
			"ProgramArguments": [binary, "bay", "start"],
			"EnvironmentVariables": ["CRYO_HOME": paths.root.path],
			"RunAtLoad": true,
			// Restart after a crash or failed start, not after a clean stop. The throttle keeps a
			// bay without an image from spinning; once one is built it comes up within a minute.
			"KeepAlive": ["SuccessfulExit": false],
			"ThrottleInterval": 60,
			// No background throttling of restores.
			"ProcessType": "Interactive",
			"LimitLoadToSessionType": "Aqua",
			"StandardOutPath": paths.log.path,
			"StandardErrorPath": paths.log.path,
		]
		return try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
	}

	/// Drops 10.77/16 bindings from bootpd's lease file. vmnet's DHCP reservation doesn't reach
	/// bootpd, so a stale binding of a capsule's .2 to another MAC moved that guest to .3.
	/// bootpd is stopped first so it can't write its old table back; launchd restarts it on demand.
	static let clearCapsuleDHCP =
		"/usr/bin/killall bootpd 2>/dev/null; /usr/bin/perl -0pi -e 's/\\{[^{}]*ip_address=10\\.77\\.[^{}]*\\}\\n?//g' \(HostFacts.dhcpLeases) 2>/dev/null"

	static func helperPlistData() throws -> Data {
		let plist: [String: Any] = [
			"Label": helperLabel,
			// `pfctl -E` takes an enable reference, so pf stays on even when InternetSharing drops its own.
			"ProgramArguments": ["/bin/sh", "-c", "\(clearCapsuleDHCP); /sbin/pfctl -a \(pfAnchor) -f '\(helperRules)' && /sbin/pfctl -E"],
			"RunAtLoad": true,
			"StandardOutPath": helperLog,
			"StandardErrorPath": helperLog,
		]
		return try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
	}

	/// Creates `~/.cryo` (no-Spotlight) and writes a default config.toml unless one exists. Returns
	/// whether it wrote the config.
	@discardableResult
	static func prepareHome(_ paths: BayPaths) throws -> Bool {
		try paths.prepare()
		guard !FileManager.default.fileExists(atPath: paths.config.path) else { return false }
		try BayConfig().save(paths.config)
		return true
	}

	// MARK: Commands

	@MainActor
	static func install(_ args: [String], paths: BayPaths, out: BayCommand.Writer) async throws -> Int32 {
		guard args.isEmpty else { throw BayError("usage: cryo bay install") }
		guard let executable = Bundle.main.executablePath else { throw BayError("can't tell where this cryo binary is") }
		let binary = launchAgentExecutablePath(executable)
		if let folder = HostDoctor.protectedFolder(holding: binary, home: FileManager.default.homeDirectoryForCurrentUser.path) {
			throw BayError("\(binary) is under ~/\(folder), where vmnet refuses to run; install it elsewhere first (scripts/install.sh uses ~/.cryo/bin)")
		}

		if try prepareHome(paths) { out("wrote \(paths.config.path)\n") }
		out("ready: \(paths.root.path) (excluded from Spotlight)\n")

		// Root helper before the agent, so the fence is up before any capsule thaws.
		let helper = try helperPlistData()
		let rules = Data(pfRules.utf8)
		let fm = FileManager.default
		if fm.contents(atPath: helperPlist) == helper && fm.contents(atPath: helperRules) == rules {
			out("root helper already installed: \(helperPlist)\n")
		} else {
			let stage = fm.temporaryDirectory.appending(path: "cryo-install-\(UUID().uuidString)", directoryHint: .isDirectory)
			try fm.createDirectory(at: stage, withIntermediateDirectories: true)
			defer { try? fm.removeItem(at: stage) }
			let stagedPlist = stage.appending(path: "helper.plist")
			let stagedRules = stage.appending(path: "cryo.pf")
			try helper.write(to: stagedPlist)
			try rules.write(to: stagedRules)
			let q = LeaseInputs.shellQuote
			let script = """
				set -e
				mkdir -p \(q((helperRules as NSString).deletingLastPathComponent))
				install -m 644 -o root -g wheel \(q(stagedRules.path)) \(q(helperRules))
				install -m 644 -o root -g wheel \(q(stagedPlist.path)) \(q(helperPlist))
				launchctl bootout system/\(helperLabel) 2>/dev/null || true
				launchctl bootstrap system \(q(helperPlist))
				"""
			out("installing the root helper that loads the pf anchor at boot (sudo)\n")
			// On the terminal, so sudo can ask for the password.
			let status = await runForeground("/usr/bin/sudo", ["/bin/sh", "-c", script])
			guard status == 0 else { throw BayError("installing the root helper failed (exit \(status)); see sudo's output above") }
			out("root helper installed: \(helperPlist)\n")
		}

		let plist = agentPlist(home: fm.homeDirectoryForCurrentUser)
		try fm.createDirectory(at: plist.deletingLastPathComponent(), withIntermediateDirectories: true)
		try agentPlistData(binary: binary, paths: paths).write(to: plist, options: .atomic)
		let domain = "gui/\(getuid())"
		if await runProcess("/bin/launchctl", ["bootout", "\(domain)/\(agentLabel)"]).status == 0 {
			out("unloaded the previous bay LaunchAgent (a running bay stops and ends its leases)\n")
		}
		// A bootstrap right after a bootout can fail while launchd is still tearing the job down.
		var r = await runProcess("/bin/launchctl", ["bootstrap", domain, plist.path])
		for _ in 0..<10 where r.status != 0 {
			try await Task.sleep(for: .seconds(1))
			r = await runProcess("/bin/launchctl", ["bootstrap", domain, plist.path])
		}
		guard r.status == 0 else { throw BayError("launchctl bootstrap \(domain) \(plist.path) failed: \(r.out)") }
		out("bay LaunchAgent installed: \(plist.path) (runs \(binary) bay start at login; log \(paths.log.path))\n")
		return 0
	}

	@MainActor
	static func uninstall(_ args: [String], paths: BayPaths, out: BayCommand.Writer) async throws -> Int32 {
		guard args.isEmpty else { throw BayError("usage: cryo bay uninstall") }
		let fm = FileManager.default
		let plist = agentPlist(home: fm.homeDirectoryForCurrentUser)
		if await runProcess("/bin/launchctl", ["bootout", "gui/\(getuid())/\(agentLabel)"]).status == 0 {
			out("stopped the bay\n")
		}
		if fm.fileExists(atPath: plist.path) {
			try fm.removeItem(at: plist)
			out("removed \(plist.path)\n")
		}
		if fm.fileExists(atPath: helperPlist) || fm.fileExists(atPath: helperRules) {
			let q = LeaseInputs.shellQuote
			let script = """
				launchctl bootout system/\(helperLabel) 2>/dev/null
				rm -f \(q(helperPlist))
				rm -rf \(q((helperRules as NSString).deletingLastPathComponent))
				pfctl -a \(pfAnchor) -F all 2>/dev/null
				true
				"""
			out("removing the root helper and the pf anchor (sudo)\n")
			// On the terminal, so sudo can ask for the password.
			let status = await runForeground("/usr/bin/sudo", ["/bin/sh", "-c", script])
			guard status == 0 else { throw BayError("removing the root helper failed (exit \(status)); see sudo's output above") }
			out("removed \(helperPlist)\n")
		}
		out("kept \(paths.root.path) (images, capsules, config); delete it by hand to remove everything\n")
		return 0
	}
}

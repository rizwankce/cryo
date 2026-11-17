import CryoClient
import CryoHTTP
import CryoServer
import Foundation

/// `cryo deck install` / `uninstall`: run `cryo deck start` at login. A LaunchAgent on macOS, a
/// systemd user unit on Linux. The text of both is made by pure functions (tests); the code that
/// talks to launchctl or systemctl is behind `#if os(...)`.
public enum DeckInstall {
	public static let agentLabel = "dev.rizwan.cryo.deck"
	public static let unitName = "cryo-deck.service"

	public static func agentPlist(home: String) -> String { home + "/Library/LaunchAgents/\(agentLabel).plist" }
	public static func unitPath(home: String) -> String { home + "/.config/systemd/user/\(unitName)" }

	public static func launchAgentData(binary: String, paths: DeckPaths) throws -> Data {
		let plist: [String: Any] = [
			"Label": agentLabel,
			"ProgramArguments": [binary, "deck", "start"],
			"EnvironmentVariables": ["CRYO_HOME": paths.root.path],
			"RunAtLoad": true,
			// Restart after a crash or a failed start, not after a clean stop.
			"KeepAlive": ["SuccessfulExit": false],
			"ThrottleInterval": 30,
			"StandardOutPath": paths.log.path,
			"StandardErrorPath": paths.log.path,
		]
		return try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
	}

	public static func systemdUnit(binary: String, paths: DeckPaths) -> String {
		func q(_ s: String) -> String { "\"" + s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\"" }
		return """
			[Unit]
			Description=cryo deck: several bays behind one /v1 endpoint
			After=network-online.target
			Wants=network-online.target

			[Service]
			ExecStart=\(q(binary)) deck start
			Environment=\(q("CRYO_HOME=" + paths.root.path))
			Restart=on-failure
			RestartSec=5
			StandardOutput=append:\(paths.log.path)
			StandardError=append:\(paths.log.path)

			[Install]
			WantedBy=default.target

			"""
	}

	/// `--listen` is written into deck.toml (as the bay's install does), so the service needs no arguments.
	public static func install(listen: String?, executable: String, paths: DeckPaths, out: (String) -> Void) throws -> Int32 {
		let binary = launchAgentExecutablePath(executable)
		try makeDirs(paths.root.path, mode: 0o700)
		if let listen {
			guard BayServer.parseListen(listen) != nil else { throw DeckError("--listen takes :PORT, PORT or HOST:PORT") }
			var config = try DeckConfig.load(paths.config)
			config.listen = listen
			try config.save(paths.config)
			out("listen = \"\(listen)\" saved in \(paths.config.path)\n")
		}
		_ = try BearerToken.create(paths.token)
		let home = ProcessInfo.processInfo.environment["HOME"] ?? NSHomeDirectory()
		#if os(macOS)
			let plist = agentPlist(home: home)
			try makeDirs((plist as NSString).deletingLastPathComponent, mode: 0o755)
			try launchAgentData(binary: binary, paths: paths).write(to: URL(filePath: plist), options: .atomic)
			let domain = "gui/\(getuid())"
			if run("/bin/launchctl", ["bootout", "\(domain)/\(agentLabel)"]).status == 0 { out("unloaded the previous deck\n") }
			var r = run("/bin/launchctl", ["bootstrap", domain, plist])
			// A bootstrap right after a bootout can fail while launchd is still tearing the job down.
			for _ in 0..<10 where r.status != 0 {
				sleep(1)
				r = run("/bin/launchctl", ["bootstrap", domain, plist])
			}
			guard r.status == 0 else { throw DeckError("launchctl bootstrap \(domain) \(plist) failed: \(r.output)") }
			out("deck LaunchAgent installed: \(plist) (runs \(binary) deck start at login; log \(paths.log.path))\n")
			return 0
		#elseif os(Linux)
			let unit = unitPath(home: home)
			try makeDirs((unit as NSString).deletingLastPathComponent, mode: 0o755)
			try systemdUnit(binary: binary, paths: paths).write(toFile: unit, atomically: true, encoding: .utf8)
			for args in [["daemon-reload"], ["enable", "--now", unitName]] {
				let r = run("/usr/bin/env", ["systemctl", "--user"] + args)
				guard r.status == 0 else { throw DeckError("systemctl --user \(args.joined(separator: " ")) failed: \(r.output)") }
			}
			out("deck service installed: \(unit) (log \(paths.log.path))\n")
			out("to start it at boot, before you log in: loginctl enable-linger \(NSUserName())\n")
			return 0
		#else
			throw DeckError("cryo deck install: macOS and Linux only")
		#endif
	}

	public static func uninstall(paths: DeckPaths, out: (String) -> Void) throws -> Int32 {
		let home = ProcessInfo.processInfo.environment["HOME"] ?? NSHomeDirectory()
		#if os(macOS)
			let plist = agentPlist(home: home)
			if run("/bin/launchctl", ["bootout", "gui/\(getuid())/\(agentLabel)"]).status == 0 { out("stopped the deck\n") }
			if FileManager.default.fileExists(atPath: plist) {
				try FileManager.default.removeItem(atPath: plist)
				out("removed \(plist)\n")
			}
		#elseif os(Linux)
			let unit = unitPath(home: home)
			if FileManager.default.fileExists(atPath: unit) {
				_ = run("/usr/bin/env", ["systemctl", "--user", "disable", "--now", unitName])
				try FileManager.default.removeItem(atPath: unit)
				_ = run("/usr/bin/env", ["systemctl", "--user", "daemon-reload"])
				out("removed \(unit)\n")
			}
		#endif
		out("kept \(paths.root.path) (deck.toml, deck-token); delete them by hand to remove everything\n")
		return 0
	}

	private static func run(_ tool: String, _ args: [String]) -> (status: Int32, output: String) {
		let p = Process()
		p.executableURL = URL(filePath: tool)
		p.arguments = args
		let pipe = Pipe()
		p.standardOutput = pipe
		p.standardError = pipe
		do { try p.run() } catch { return (127, "\(error)") }
		let data = pipe.fileHandleForReading.readDataToEndOfFile()
		p.waitUntilExit()
		return (p.terminationStatus, String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines))
	}
}

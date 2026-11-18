import CryoAPI
import CryoClient
import CryoHTTP
import CryoServer
import Foundation

/// `cryo deck <subcommand>` (docs/spec/deck.md). The deck is for a LAN or VPN: plain HTTP and
/// tokens, no TLS.
public enum DeckCommand {
	public static let help = """
		usage: cryo deck <command>

		Several Macs' bays behind one /v1 endpoint, so any Mac or Linux machine leases from the
		whole pool. Plain HTTP and bearer tokens: for a LAN or VPN (Tailscale) only, no TLS.

		commands:
		  add <name> <url> <token>   add a bay (checks it answers with that token first)
		  rm <name>                  remove a bay (its leases are not touched; the deck forgets them)
		  ls [--json]                bays: online or offline, capsules (thawed/leased/other), image
		  token [--rotate]           print the clients' token (made on first use)
		  start [--listen :7400]     run the deck in the foreground (Ctrl-C stops it)
		  install [--listen :7400]   run it at login (LaunchAgent on macOS, systemd user unit on Linux)
		  uninstall                  remove that
		  help

		The deck reads ~/.cryo/deck.toml (or $CRYO_HOME) once, when it starts: after `add` or `rm`,
		restart it. Clients use CRYO_URL=http://<deck>:7400 and CRYO_TOKEN=<deck token>, or the
		deck's unix socket (deck.sock, no token) on the deck machine.

		"""

	public typealias Writer = (String) -> Void

	/// `executable`: this binary's path, for `install`.
	public static func main(
		_ args: [String], environment: [String: String], executable: String?, version: String,
		out: @escaping Writer, err: @escaping Writer
	) -> Int32 {
		guard let sub = args.first else {
			out(help)
			return 0
		}
		let rest = Array(args.dropFirst())
		let paths = DeckPaths.standard(environment: environment)
		do {
			switch sub {
			case "help", "--help", "-h":
				out(help)
				return 0
			case "add": return try add(rest, paths, out)
			case "rm": return try remove(rest, paths, out)
			case "ls": return try list(rest, paths, out)
			case "token": return try token(rest, paths, out)
			case "start":
				let flags = try parseFlags(rest, values: ["listen"], bools: [])
				if flags.help {
					out(help)
					return 0
				}
				return try DeckRun.run(listenFlag: flags.values["listen"], paths: paths, version: version, out: out)
			case "install":
				let flags = try parseFlags(rest, values: ["listen"], bools: [])
				if flags.help {
					out(help)
					return 0
				}
				guard let executable else { throw DeckError("can't tell where this cryo binary is") }
				return try DeckInstall.install(listen: flags.values["listen"], executable: executable, paths: paths, out: out)
			case "uninstall":
				let flags = try parseFlags(rest, values: [], bools: [])
				if flags.help {
					out(help)
					return 0
				}
				return try DeckInstall.uninstall(paths: paths, out: out)
			default:
				err("cryo deck: unknown command '\(sub)'\n\n\(help)")
				return 2
			}
		} catch let e as UsageError {
			err("cryo deck \(sub): \(e.message)\n")
			return 2
		} catch {
			err("cryo deck \(sub): \(error)\n")
			return 1
		}
	}

	struct UsageError: Error { let message: String }

	struct Flags {
		var values: [String: String] = [:]
		var bools: Set<String> = []
		var positionals: [String] = []
		var help = false
	}

	static func parseFlags(_ args: [String], values: Set<String>, bools: Set<String>) throws -> Flags {
		var f = Flags()
		var i = 0
		while i < args.count {
			let a = args[i]
			i += 1
			if a == "-h" || a == "--help" {
				f.help = true
			} else if a.hasPrefix("--") {
				var name = String(a.dropFirst(2))
				var inline: String?
				if let eq = name.firstIndex(of: "=") {
					inline = String(name[name.index(after: eq)...])
					name = String(name[..<eq])
				}
				if values.contains(name) {
					if let inline {
						f.values[name] = inline
					} else {
						guard i < args.count else { throw UsageError(message: "--\(name) needs a value") }
						f.values[name] = args[i]
						i += 1
					}
				} else if bools.contains(name), inline == nil {
					f.bools.insert(name)
				} else {
					throw UsageError(message: "unknown option --\(name)")
				}
			} else {
				f.positionals.append(a)
			}
		}
		return f
	}

	// MARK: add, rm

	/// Whether a deck answers on its socket. It reads deck.toml only at start, so it needs a restart.
	static func deckRunning(_ paths: DeckPaths) -> Bool {
		guard let s = try? Socket.connectUnix(path: paths.socket.path) else { return false }
		s.close()
		return true
	}

	static let restartNote = "restart the deck to apply (`cryo deck start` / launchctl kickstart)\n"

	static func add(_ args: [String], _ paths: DeckPaths, _ out: Writer) throws -> Int32 {
		let f = try parseFlags(args, values: [], bools: [])
		if f.help {
			out(help)
			return 0
		}
		guard f.positionals.count == 3 else { throw UsageError(message: "usage: cryo deck add <name> <url> <token>") }
		let entry = BayEntry(name: f.positionals[0], url: f.positionals[1], token: f.positionals[2])
		guard BayEntry.validName(entry.name) else { throw UsageError(message: "a bay name uses a-z, 0-9 and -, got '\(entry.name)'") }
		var config = try DeckConfig.load(paths.config)
		if config.bay(named: entry.name) != nil { throw DeckError("bay '\(entry.name)' exists; `cryo deck rm \(entry.name)` first") }
		let client = try defaultBayClient(entry)
		do {
			let s = try client.status(timeout: 5)
			out("\(entry.name) answers: version \(s.bay.version), \(s.capsules.count) capsule(s)\n")
		} catch {
			throw DeckError("\(entry.url) did not answer GET /v1/status with that token: \(error)")
		}
		config.bays.append(entry)
		try config.save(paths.config)
		out("added \(entry.name) to \(paths.config.path)\n")
		if deckRunning(paths) { out(restartNote) }
		return 0
	}

	static func remove(_ args: [String], _ paths: DeckPaths, _ out: Writer) throws -> Int32 {
		let f = try parseFlags(args, values: [], bools: [])
		if f.help {
			out(help)
			return 0
		}
		guard f.positionals.count == 1 else { throw UsageError(message: "usage: cryo deck rm <name>") }
		let name = f.positionals[0]
		var config = try DeckConfig.load(paths.config)
		guard config.bay(named: name) != nil else { throw DeckError("no bay named '\(name)' (cryo deck ls)") }
		config.bays.removeAll { $0.name == name }
		try config.save(paths.config)
		out("removed \(name); its leases are not touched, the deck forgets them\n")
		if deckRunning(paths) { out(restartNote) }
		return 0
	}

	// MARK: ls, token

	static func list(_ args: [String], _ paths: DeckPaths, _ out: Writer) throws -> Int32 {
		let f = try parseFlags(args, values: [], bools: ["json"])
		if f.help {
			out(help)
			return 0
		}
		guard f.positionals.isEmpty else { throw UsageError(message: "unexpected argument '\(f.positionals[0])'") }
		let config = try DeckConfig.load(paths.config)
		let rows = queryBays(config.bays)
		if f.bools.contains("json") {
			let e = CryoJSON.encoder()
			e.outputFormatting.insert(.prettyPrinted)
			out(String(decoding: try e.encode(rows), as: UTF8.self) + "\n")
			return 0
		}
		if rows.isEmpty {
			out("no bays: cryo deck add <name> <url> <token>\n")
			return 0
		}
		var table = [["bay", "state", "capsules", "image", "url"]]
		for r in rows {
			let thawed = r.capsules.filter { $0.state == "thawed" }.count
			let leased = r.capsules.filter { $0.state == "leased" }.count
			let other = r.capsules.count - thawed - leased
			table.append([
				r.name, r.online ? "online" : "offline",
				r.online ? "\(thawed) thawed, \(leased) leased, \(other) other" : "-", r.image.map { String($0.prefix(12)) } ?? "-", r.url,
			])
		}
		out(formatTable(table))
		return 0
	}

	/// One status call per bay, all at once.
	static func queryBays(_ bays: [BayEntry]) -> [Status.DeckBay] {
		let box = Results(count: bays.count)
		let done = Monitor()
		for (i, b) in bays.enumerated() {
			spawnThread {
				var row = Status.DeckBay(name: b.name, url: b.url, online: false)
				if let c = try? defaultBayClient(b), let s = try? c.status(timeout: 3) {
					row = Status.DeckBay(
						name: b.name, url: b.url, online: true, capsules: s.capsules, image: s.bay.image, version: s.bay.version)
				}
				done.withLock {
					box.rows[i] = row
					done.broadcast()
				}
			}
		}
		done.lock()
		while box.rows.contains(where: { $0 == nil }) { done.wait() }
		done.unlock()
		return box.rows.compactMap { $0 }
	}

	private final class Results: @unchecked Sendable {
		var rows: [Status.DeckBay?]
		init(count: Int) { rows = Array(repeating: nil, count: count) }
	}

	static func token(_ args: [String], _ paths: DeckPaths, _ out: Writer) throws -> Int32 {
		let f = try parseFlags(args, values: [], bools: ["rotate"])
		if f.help {
			out(help)
			return 0
		}
		guard f.positionals.isEmpty else { throw UsageError(message: "unexpected argument '\(f.positionals[0])'") }
		let t = try BearerToken.create(paths.token, rotate: f.bools.contains("rotate"))
		out(t + "\n")
		if f.bools.contains("rotate"), deckRunning(paths) { out(restartNote) }
		return 0
	}
}

func formatTable(_ rows: [[String]]) -> String {
	guard let first = rows.first else { return "" }
	var widths = [Int](repeating: 0, count: first.count)
	for r in rows { for (i, c) in r.enumerated() { widths[i] = max(widths[i], c.count) } }
	return rows.map { r in
		r.enumerated().map { i, c in i == r.count - 1 ? c : c + String(repeating: " ", count: widths[i] - c.count + 2) }.joined()
	}.joined(separator: "\n") + "\n"
}

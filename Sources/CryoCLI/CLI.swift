import CryoAPI
import CryoClient
import CryoHTTP
import CryoMCP

#if os(macOS)
	import CryoBay
#endif

#if canImport(FoundationEssentials)
	import FoundationEssentials
#else
	import Foundation
#endif

public enum CryoCLI {
	/// The process entry point: builds the real context and runs.
	public static func main(_ arguments: [String]) -> Int32 {
		var env: [String: String] = [:]
		for k in ["HOME", "CRYO_HOME"] {
			if let v = getenv(k) { env[k] = String(cString: v) }
		}
		let target: CryoTarget
		do {
			target = try CryoTarget.fromProcessEnvironment()
		} catch {
			// Commands that need no bay still work; the others report the bad target.
			let ctx = CLIContext.process(target: CryoTarget(endpoint: .unix(path: "/nonexistent")), home: env["HOME"] ?? "", environment: env)
			if let cmd = arguments.first, ["version", "help", "--help", "-h", "--version"].contains(cmd) || arguments.contains("--help") {
				return run(arguments, ctx)
			}
			ctx.warn("cryo: \(error)")
			return 1
		}
		return run(arguments, CLIContext.process(target: target, home: env["HOME"] ?? "", environment: env))
	}

	/// Runs one command line (without the program name) and returns the exit code.
	public static func run(_ arguments: [String], _ ctx: CLIContext) -> Int32 {
		guard let cmd = arguments.first else {
			ctx.out(Help.main)
			return 0
		}
		let rest = Array(arguments.dropFirst())
		switch cmd {
		case "-h", "--help":
			ctx.out(Help.main)
			return 0
		case "version", "--version":
			ctx.say("cryo \(cryoVersion)")
			return 0
		case "help":
			guard let topic = rest.first else {
				ctx.out(Help.main)
				return 0
			}
			guard let text = Help.topics[topic] else {
				ctx.warn("cryo: no help for '\(topic)'")
				return 2
			}
			ctx.out(text)
			return 0
		case "lease": return guarded(ctx, cmd, rest, leaseSpec, leaseCommand)
		case "release": return guarded(ctx, cmd, rest, ArgSpec(bools: ["save-cache"]), releaseCommand)
		case "ls": return guarded(ctx, cmd, rest, ArgSpec(bools: ["json"]), lsCommand)
		case "status": return guarded(ctx, cmd, rest, ArgSpec(bools: ["json"]), statusCommand)
		case "ssh": return guarded(ctx, cmd, rest, ArgSpec(stopAtPositional: true), sshCommand)
		case "setup": return guarded(ctx, cmd, rest, ArgSpec(bools: ["yes"]), setupCommand)
		case "logs": return guarded(ctx, cmd, logsArguments(rest), ArgSpec(values: ["lines"], bools: ["follow"]), logsCommand)
		case "doctor", "bay":
			#if os(macOS)
				if cmd == "doctor" { return guarded(ctx, cmd, rest, ArgSpec(bools: ["fix"]), doctorCommand) }
				if cmd == "bay" {
					if rest.first == "start" { trimLaunchdLog(BayPaths.standard().log.path) }
					let code = BayCommand.main(rest, out: ctx.out, err: ctx.err)
					// `cryo bay install` ends with the host checks (docs/spec/setup.md "Flow").
					if code == 0 && rest.first == "install" {
						ctx.say("\nrunning cryo doctor")
						_ = run(["doctor"], ctx)
					}
					return code
				}
				return 1
			#else
				ctx.warn("cryo \(cmd): macOS bay only")
				return 1
			#endif
		case "image":
			// docs/spec/image.md: the bay owns the work.
			#if os(macOS)
				let subs = ["build": "image-build", "ls": "images", "use": "image-use", "rm": "image-rm"]
				guard let sub = rest.first.flatMap({ subs[$0] }) else {
					if rest.first == "--help" || rest.first == "-h" || rest.isEmpty {
						ctx.out(Help.topics["image"]!)
						return 0
					}
					ctx.warn("cryo image: unknown subcommand '\(rest[0])'\n")
					ctx.err(Help.topics["image"]!)
					return 2
				}
				return BayCommand.main([sub] + rest.dropFirst(), out: ctx.out, err: ctx.err)
			#else
				ctx.warn("cryo image: macOS bay only")
				return 1
			#endif
		case "mcp":
			return guarded(ctx, cmd, rest, ArgSpec()) { ctx, _ in
				runMCPOnStdio(client: ctx.client, home: ctx.home, version: cryoVersion)
			}
		case "ci":
			// GitHub Actions on capsules is its own program, cryo-ci; `cryo ci …` runs it.
			return runCryoCI(rest, ctx)
		default:
			ctx.warn("cryo: unknown command '\(cmd)'\n")
			ctx.err(Help.main)
			return 2
		}
	}

	private static var leaseSpec: ArgSpec {
		ArgSpec(values: ["folder", "cache", "name", "wait", "idle"], bools: ["json"])
	}

	/// Parses arguments (handling help and usage errors) and maps thrown errors to messages.
	static func guarded(
		_ ctx: CLIContext, _ cmd: String, _ args: [String], _ spec: ArgSpec,
		_ body: (CLIContext, ParsedArgs) throws -> Int32
	) -> Int32 {
		let parsed: ParsedArgs
		do {
			parsed = try parseArgs(args, spec)
		} catch let e as UsageError {
			ctx.warn("cryo \(cmd): \(e.message)\n")
			ctx.err(Help.topics[cmd] ?? Help.main)
			return 2
		} catch {
			return 2
		}
		if parsed.help {
			ctx.out(Help.topics[cmd] ?? Help.main)
			return 0
		}
		do {
			return try body(ctx, parsed)
		} catch let e as UsageError {
			ctx.warn("cryo \(cmd): \(e.message)")
			return 2
		} catch {
			ctx.warn("cryo \(cmd): \(describe(error))")
			return 1
		}
	}
}

func describe(_ error: Error) -> String {
	if let e = error as? CryoClientError {
		switch e {
		case .upgradeRequired: return "this cryo is too old for the bay; update it"
		case .api(let a, _): return "\(a.code): \(a.message)"
		default: return e.description
		}
	}
	return "\(error)"
}

enum Help {
	static let main = """
		cryo \(cryoVersion): frozen Macs, thawed in seconds

		usage: cryo <command> [options]

		commands:
		  lease      lease a capsule (a clean macOS VM) and write its SSH entry
		  release    give a lease back
		  ls         list your leases
		  status     bay, health, capsules, queue
		  ssh        open a shell or run a command in a lease (or act as the ProxyCommand)
		  setup      add `Include ~/.cryo/ssh_config` to ~/.ssh/config
		  doctor     check the bay host (macOS bay only)
		  logs       bay logs (macOS bay only)
		  bay        run the bay (macOS only)
		  image      build, list, switch and remove golden images (macOS bay only)
		  mcp        MCP server over stdio
		  ci         run GitHub Actions jobs on capsules (runs cryo-ci; `cryo ci --help`)
		  version    print the version

		Target: CRYO_URL (default unix://~/.cryo/bay.sock) and CRYO_TOKEN.
		Run `cryo <command> --help` for details.

		"""

	static let topics: [String: String] = [
		"lease": """
		usage: cryo lease [--folder PATH] [--cache NAME] [--name NAME] [--wait SECONDS] [--idle DURATION] [--json]

		  --folder PATH   folder on the bay's Mac to clone into the capsule
		  --cache NAME    named cache to mount
		  --name NAME     label for the lease
		  --wait SECONDS  how long to queue for a free capsule (default: the bay's, 600 unless
		                  configured; 0 fails at once)
		  --idle DURATION idle timeout: 90s, 60m, 2h or bare minutes (default: the bay's, 60m
		                  unless configured; max 24h)
		  --json          print the lease as JSON

		Prints `L81 ready: ssh cryo-L81`.

		""",
		"release": """
		usage: cryo release <id> [--save-cache]

		Releases a lease and removes its local key and ssh_config entry.

		""",
		"ls": """
		usage: cryo ls [--json]

		Lists your leases; forgets local keys of this bay's leases that it no longer has.

		""",
		"status": """
		usage: cryo status [--json]

		Shows the bay, its health and counters, each capsule and the queue.

		""",
		"ssh": """
		usage: cryo ssh <id> [command...]

		With a command: runs it in the lease over ssh, with or without a terminal.
		Without one, in a terminal: opens a shell in the lease.
		Without one, stdin not a terminal: acts as ssh's ProxyCommand, piping stdin/stdout to the
		capsule's sshd (the lease's ssh_config entry uses this).

		""",
		"setup": """
		usage: cryo setup [--yes]

		Adds `Include ~/.cryo/ssh_config` to the top of ~/.ssh/config, after asking.
		  --yes   do not ask

		""",
		"mcp": """
		usage: cryo mcp

		Runs an MCP server on stdin/stdout with the tools lease_mac, run, copy_in, copy_out,
		release_mac and status. It renews its leases every minute and releases them when it exits.

		""",
		"doctor":
			"usage: cryo doctor [--fix]\n\nChecks the bay host (macOS bay only); host checks only when no bay runs.\n--fix turns off sleep and automatic macOS updates (sudo) and excludes ~/.cryo from Spotlight.\nIt never changes FileVault or auto-login.\n",
		"logs": """
		usage: cryo logs [-n LINES] [-f]

		Prints the end of the bay's log on the bay's Mac: ~/.cryo/bay.log ($CRYO_HOME/bay.log when
		set), where the installed bay (`cryo bay install`) writes. macOS bay only.
		  -n, --lines N   how many lines (default \(defaultLogLines))
		  -f, --follow    keep printing what the bay writes (Ctrl-C stops)

		""",
		"image": """
		usage: cryo image build [--xcode | --xcode-xip PATH] [--runtime iOS|none] [--run ./setup.sh] [--tag NAME]
		       cryo image ls
		       cryo image use IMAGE [--warm-up [ios,macos] | --no-warm-up] [--settle 45] [--verify-tries 4]
		       cryo image rm IMAGE

		Builds a golden image on this Mac, lists images, puts one in service or deletes one.
		IMAGE is a digest, a unique digest prefix or a tag. `use` freezes every capsule on the image
		(each checked by a thaw), then sets it in config.toml; `rm` refuses the image in use.
		Stop the bay before `build` and `use` (Apple allows 2 VMs per Mac; stopping the bay ends its
		leases), start it again after. `cryo image build --help` shows every option. macOS bay only.

		""",
		"bay": """
		usage: cryo bay start [--listen :7477] | install | uninstall | token | help

		Runs the bay (macOS only); `cryo bay help` lists every subcommand.
		The installed bay is the LaunchAgent dev.cryo.bay (stopping it ends its leases):
		  stop     launchctl bootout gui/$(id -u)/dev.cryo.bay
		  restart  launchctl kickstart -k gui/$(id -u)/dev.cryo.bay
		  start    cryo bay install (loads it again)
		A bay started with `cryo bay start` in a terminal stops with Ctrl-C.

		""",
	]
}

/// `cryo ci …`: runs `cryo-ci` with the same arguments, the one next to this program (both install
/// to ~/.cryo/bin), else the first on PATH.
func runCryoCI(_ args: [String], _ ctx: CLIContext) -> Int32 {
	let dir = currentExecutablePath().split(separator: "/", omittingEmptySubsequences: false).dropLast().joined(separator: "/")
	let beside = dir + "/cryo-ci"
	let program = !dir.isEmpty && access(beside, X_OK) == 0 ? beside : "cryo-ci"
	let code = ctx.exec([program] + args)
	if code == 127 { ctx.warn("cryo ci: install cryo-ci next to cryo (brew install rizwankce/tap/cryo-ci)") }
	return code
}

/// launchd opens a LaunchAgent's log once and appends to it for good, so nothing rotates
/// `bay.log` or `ci.log`. At start, when stdout is that file and it is over 10 MB, keep one old
/// copy in `<log>.1` and empty the log; stdout is in append mode, so writes go on from the start.
func trimLaunchdLog(_ path: String, maxBytes: Int = 10 << 20) {
	#if os(macOS)
		var out = stat()
		var file = stat()
		guard fstat(STDOUT_FILENO, &out) == 0, stat(path, &file) == 0,
			out.st_dev == file.st_dev, out.st_ino == file.st_ino, Int(out.st_size) > maxBytes
		else { return }
		try? FileManager.default.removeItem(atPath: path + ".1")
		guard (try? FileManager.default.copyItem(atPath: path, toPath: path + ".1")) != nil else { return }
		ftruncate(STDOUT_FILENO, 0)
	#endif
}

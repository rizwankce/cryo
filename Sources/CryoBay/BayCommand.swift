import Foundation
import os

/// Unified log, subsystem `dev.cryo.bay` (docs/spec/bay.md "Process"). `cryo logs` prints the bay's `bay.log` instead.
public enum BayLog {
	public static let bay = Logger(subsystem: "dev.cryo.bay", category: "bay")
	public static let vm = Logger(subsystem: "dev.cryo.bay", category: "vm")
}

/// `cryo bay <subcommand>`. Each subcommand is added by the part of the bay that owns it.
public enum BayCommand {
	public typealias Writer = (String) -> Void

	struct Sub {
		let summary: String
		/// Main actor: Virtualization.framework objects belong to the main thread.
		let run: @MainActor ([String], BayPaths, Writer, Writer) async throws -> Int32
	}

	/// Subcommands by name. Kept in one table so `cryo bay help` lists them all.
	nonisolated(unsafe) static var subcommands: [String: Sub] = [
		"paths": Sub(summary: "print where the bay keeps its files") { _, paths, out, _ in
			out("root      \(paths.root.path)\nconfig    \(paths.config.path)\nsocket    \(paths.socket.path)\n")
			return 0
		},
		"config": Sub(summary: "print the effective config") { _, paths, out, _ in
			out(try BayConfig.load(paths.config).text())
			return 0
		},
		"image-build": Sub(summary: "what `cryo image build` runs (see `cryo image --help`)") { args, paths, out, _ in
			try await ImageBuild.command(args, paths: paths, out: out)
		},
		"image-use": Sub(summary: "what `cryo image use` runs: freeze the capsules on an image and switch to it (bay stopped)") { args, paths, out, _ in
			try await ImageUse.use(args, paths: paths, out: out)
		},
		"image-rm": Sub(summary: "what `cryo image rm` runs: delete an image not in use") { args, paths, out, _ in
			try ImageUse.rm(args, paths: paths, out: out)
		},
		"images": Sub(summary: "list the images") { _, paths, out, _ in BayInventory.images(paths: paths, out: out) },
		"capsules": Sub(summary: "list capsules and whether their saved state still matches") { _, paths, out, _ in
			BayInventory.capsules(paths: paths, out: out)
		},
		"freeze": Sub(summary: "freeze a capsule: --capsule N --subnet S [--settle 45]") { args, paths, out, _ in
			try await Freeze.freeze(args, paths: paths, out: out)
		},
		"thaw-test": Sub(summary: "restore, refill and lease a capsule to prove the driver: --capsule N [--runs 3]") { args, paths, out, _ in
			try await Freeze.thawTest(args, paths: paths, out: out)
		},
		"token": Sub(summary: "print the network listener's bearer token (--rotate makes a new one)") { args, paths, out, _ in
			try BayToken.command(args, paths: paths, out: out)
		},
		"start": Sub(summary: "refill the capsules and serve the API: [--listen :7477]") { args, paths, out, _ in
			try await BayStart.run(args, paths: paths, out: out)
		},
		"install": Sub(summary: "set up this Mac: ~/.cryo, the bay's LaunchAgent, the pf root helper (one sudo)") { args, paths, out, _ in
			try await BayInstall.install(args, paths: paths, out: out)
		},
		"uninstall": Sub(summary: "remove the LaunchAgent and the root helper; keeps ~/.cryo") { args, paths, out, _ in
			try await BayInstall.uninstall(args, paths: paths, out: out)
		},
		"lease-test": Sub(summary: "the bay end to end, no server: [--folder DIR] [--cache NAME] [--runs 2] [--queue]") { args, paths, out, _ in
			try await LeaseTest.run(args, paths: paths, out: out)
		},
	]

	/// Entry point from the CLI. Runs the async subcommand on the main actor's run loop, since
	/// Virtualization.framework objects belong to the main thread.
	public static func main(_ args: [String], out: @escaping Writer, err: @escaping Writer) -> Int32 {
		let name = args.first ?? "help"
		let rest = Array(args.dropFirst())
		if name == "help" || name == "--help" || name == "-h" {
			out(usage())
			return 0
		}
		guard let sub = subcommands[name] else {
			err("cryo bay: unknown subcommand '\(name)'\n\(usage())")
			return 2
		}
		let paths = BayPaths.standard()
		// The CLI's writers aren't Sendable; this thread only waits in the run loop while the task runs.
		let box = ResultBox(out: out, err: err)
		Task { @MainActor in
			do {
				box.code = try await sub.run(rest, paths, box.out, box.err)
			} catch {
				box.err("cryo bay \(name): \(error)\n")
				box.code = 1
			}
			CFRunLoopStop(CFRunLoopGetMain())
		}
		CFRunLoopRun()
		return box.code
	}

	static func usage() -> String {
		var s = "usage: cryo bay <subcommand>\n"
		for k in subcommands.keys.sorted() { s += "  \(k.padding(toLength: 12, withPad: " ", startingAt: 0)) \(subcommands[k]!.summary)\n" }
		return s
	}
}

private final class ResultBox: @unchecked Sendable {
	var code: Int32 = 0
	let out: BayCommand.Writer
	let err: BayCommand.Writer
	init(out: @escaping BayCommand.Writer, err: @escaping BayCommand.Writer) {
		self.out = out
		self.err = err
	}
}

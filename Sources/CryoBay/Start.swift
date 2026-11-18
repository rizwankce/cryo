import CryoAPI
import CryoServer
import Foundation

/// `cryo bay start [--listen :7477]` (default: `listen` in config.toml): serve the API, refill the capsules (once `cryo doctor`
/// passes) behind it, run until a signal.
/// A signal stops every VM before exit; a restart ends every lease (bay.md), and the next
/// start clears stale lease folders and the stale socket.
enum BayStart {
	@MainActor
	static func run(_ args: [String], paths: BayPaths, out: BayCommand.Writer) async throws -> Int32 {
		var flag: (host: String, port: Int)?
		var i = 0
		while i < args.count {
			switch args[i] {
			case "--listen":
				i += 1
				guard i < args.count, let l = BayServer.parseListen(args[i]) else {
					throw BayError("--listen takes :PORT, PORT or HOST:PORT")
				}
				flag = l
			default:
				throw BayError("usage: cryo bay start [--listen :7477]")
			}
			i += 1
		}

		// The flag wins over config.toml's `listen`; a bad config fails the start before any VM does.
		let listen = try BayConfig.load(paths.config).listener(flag: flag)

		// The bay's trace (refills, leases, releases, failures) goes to stdout with a timestamp as
		// well as the unified log, so a terminal or LaunchAgent log shows what happened.
		BayTrace.sink = { line in
			let f = ISO8601DateFormatter()
			f.formatOptions = [.withTime, .withColonSeparatorInTime]
			print("\(f.string(from: Date())) \(line)")
			fflush(stdout)
		}
		return try await CapsuleVM.session {
			let bay = Bay(paths: paths)
			// A signal shuts the bay down before the VMs stop and the process exits: otherwise a
			// refill waking from its backoff, or one after a release, could thaw a VM while they stop
			// and leave it and its vmnet subnet behind.
			CapsuleVM.beforeSignalExit = { await bay.shutdown(within: .seconds(10)) }
			// No lease is held when this fires (RestartPolicy). Either no VM runs, or the bay has already
			// stopped them (`afterSharingRestart`); `shutdown()` here would wait on the refill task that calls it.
			let note = paths.root.appending(path: RestartNote.fileName)
			bay.onRestartNeeded = {
				let alert = bay.subnetAlert ?? "capsule subnets taken; run `\(SubnetAlert.command)`"
				try? Data(RestartNote.text(alert: alert, now: Date().timeIntervalSince1970).utf8).write(to: note, options: .atomic)
				print(
					"exiting (\(RestartPolicy.exitCode)) for a restart: the LaunchAgent starts a new bay within a minute; in a terminal, run `cryo bay start` again (after `sudo killall InternetSharing` if the subnets stay taken)"
				)
				fflush(stdout)
				exit(RestartPolicy.exitCode)
			}
			let t0 = Date()
			out("starting the bay in \(paths.root.path)\n")
			// The API is up before the capsules: status answers and leases queue while they thaw, so one
			// capsule whose guest doesn't answer (minutes of retries) doesn't hide the other.
			try await bay.start(waitForRefills: false)
			let token = listen == nil ? nil : try BayToken.create(paths, rotate: false)
			let server = BayServer(service: bay, socketPath: paths.socket.path)
			try server.start(listen: listen, token: token)
			try? FileManager.default.removeItem(at: note)
			out(String(format: "serving %@ after %.1f s; thawing the capsules\n", paths.socket.path, Date().timeIntervalSince(t0)))
			await bay.firstRefills()
			let status = await bay.status()
			out(
				String(
					format: "ready in %.1f s: image %@, %d capsule(s), socket %@\n",
					Date().timeIntervalSince(t0), status.bay.image, status.capsules.count, paths.socket.path))
			for c in status.capsules { out("  capsule \(c.n): \(c.state)\n") }
			if let blocked = status.bay.blockedBy {
				out("  capsules stay frozen until cryo doctor passes (re-checked every \(Bay.doctorRecheckS) s):\n")
				for check in blocked { out("    FAIL  \(check)\n") }
				out("  run `cryo doctor` for the fixes, or set ignore_doctor = true in config.toml on a dev Mac\n")
			}
			if let listen { out("  network listener on \(listen.host):\(listen.port) (token: cryo bay token)\n") }
			out("Ctrl-C stops every capsule and ends all leases\n")
			// Serve until a signal; the exit handlers stop the VMs and exit the process.
			while true { try await Task.sleep(for: .seconds(3600)) }
		}
	}
}

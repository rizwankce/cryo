import CryoAPI
import CryoClient
import Foundation

/// `cryo bay restart [--force]`: restarts the installed bay through launchd, after checking that
/// no lease is running (a restart ends them).
public enum BayRestart {
	public enum Decision: Equatable {
		case restart
		case refuse(String)
	}

	/// Refuse while leases run, unless forced. `leases` are the ids of the leased capsules.
	static func decide(leases: [String], force: Bool) -> Decision {
		guard !leases.isEmpty, !force else { return .restart }
		return .refuse("\(leases.count) lease(s) running (\(leases.joined(separator: ", "))); a restart ends them. Wait, or pass --force.")
	}

	static func leaseIDs(_ status: Status) -> [String] { status.capsules.compactMap(\.lease) }

	/// Whether `status` comes from a bay started within the last `waitedS` seconds (1 s of slack);
	/// a status without health counts as new.
	static func startedSince(_ status: Status, waitedS: Int) -> Bool {
		guard let up = status.health?.uptimeS else { return true }
		return up <= waitedS + 1
	}

	static func summary(old: String?, new: String) -> String { "bay restarted: \(old ?? "not running") → \(new)" }

	@MainActor static func command(_ args: [String], paths: BayPaths, out: BayCommand.Writer) async throws -> Int32 {
		let force = args.contains("--force")
		if let extra = args.first(where: { $0 != "--force" }) { throw BayError("usage: cryo bay restart [--force] (unexpected \(extra))") }
		let plist = BayInstall.agentPlist(home: FileManager.default.homeDirectoryForCurrentUser)
		let client = ask(paths)
		return try await perform(
			force: force, installed: FileManager.default.fileExists(atPath: plist.path), out: out,
			status: { try? client.status() },
			kickstart: { await runProcess("/bin/launchctl", ["kickstart", "-k", "gui/\(getuid())/\(BayInstall.agentLabel)"]) },
			pause: { try? await Task.sleep(for: .seconds(1)) })
	}

	/// A client for the local bay's socket with a short timeout, so a hung bay doesn't stall the restart.
	static func ask(_ paths: BayPaths) -> CryoClient {
		var c = CryoClient(target: CryoTarget(endpoint: .unix(path: paths.socket.path)))
		c.timeout = 3
		return c
	}

	/// The whole flow with launchd, the socket and the clock passed in, so tests run none of them.
	@MainActor static func perform(
		force: Bool, installed: Bool, polls: Int = 30, out: BayCommand.Writer,
		status: () -> Status?, kickstart: () async -> (status: Int32, out: String), pause: () async -> Void
	) async throws -> Int32 {
		guard installed else {
			throw BayError("the bay's LaunchAgent (\(BayInstall.agentLabel)) is not installed; run `cryo bay install`")
		}
		let before = status()
		if let before, case .refuse(let why) = decide(leases: leaseIDs(before), force: force) { throw BayError(why) }
		let r = await kickstart()
		guard r.status == 0 else {
			throw BayError("launchctl kickstart failed (exit \(r.status)): \(r.out.trimmingCharacters(in: .whitespacesAndNewlines))")
		}
		for i in 0..<polls {
			await pause()
			// The old bay can still answer while launchd stops it: wait for one started since.
			if let now = status(), startedSince(now, waitedS: i + 1) {
				out(summary(old: before?.bay.version, new: now.bay.version) + "\n")
				return 0
			}
		}
		throw BayError("the bay did not answer within \(polls) s after the restart; see `cryo logs`")
	}
}

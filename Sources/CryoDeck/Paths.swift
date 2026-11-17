import Foundation

/// The deck's files under `$CRYO_HOME`, else `~/.cryo` (the same root as the bay's `BayPaths`, which
/// the deck cannot use: it must build without the macOS-only bay).
public struct DeckPaths: Sendable, Equatable {
	public let root: URL

	public init(root: URL) { self.root = root }

	public static func standard(environment: [String: String] = ProcessInfo.processInfo.environment) -> DeckPaths {
		if let home = environment["CRYO_HOME"], !home.isEmpty {
			return DeckPaths(root: URL(filePath: home, directoryHint: .isDirectory))
		}
		let home = environment["HOME"].flatMap { $0.isEmpty ? nil : $0 } ?? NSHomeDirectory()
		return DeckPaths(root: URL(filePath: home, directoryHint: .isDirectory).appending(path: ".cryo", directoryHint: .isDirectory))
	}

	/// The bays (and optional `listen`); holds their tokens, so mode 0600.
	public var config: URL { root.appending(path: "deck.toml") }
	/// The clients' bearer token (`cryo deck token`).
	public var token: URL { root.appending(path: "deck-token") }
	/// The next deck lease number, kept so D-ids keep counting up across restarts.
	public var nextLease: URL { root.appending(path: "deck-next-lease") }
	/// The deck's unix socket: no token, for clients on the deck machine.
	public var socket: URL { root.appending(path: "deck.sock") }
	/// The installed deck's stdout and stderr.
	public var log: URL { root.appending(path: "deck.log") }
}

import CryoServer
import Foundation

extension BayPaths {
	/// The bearer token for the network listener (api.md "Auth"), mode 0600.
	public var token: URL { root.appending(path: "token") }
}

/// `~/.cryo/token`: the bay's `BearerToken` file.
public enum BayToken {
	public static func load(_ paths: BayPaths) -> String? { BearerToken.load(paths.token) }

	/// The existing token, or a new one when missing or `rotate` is set.
	@discardableResult
	public static func create(_ paths: BayPaths, rotate: Bool = false) throws -> String {
		try BearerToken.create(paths.token, rotate: rotate)
	}

	public static func generate() -> String { BearerToken.generate() }

	/// `cryo bay token [--rotate]`.
	static func command(_ args: [String], paths: BayPaths, out: BayCommand.Writer) throws -> Int32 {
		out(try create(paths, rotate: args.contains("--rotate")) + "\n")
		return 0
	}
}

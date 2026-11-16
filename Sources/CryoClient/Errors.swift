import CryoAPI

public enum CryoClientError: Error, CustomStringConvertible, Sendable {
	/// The bay could not be reached or the connection broke. `target` is e.g. `unix:///home/x/.cryo/bay.sock`.
	case transport(target: String, message: String)
	/// The bay answered with an error envelope.
	case api(APIError, status: Int)
	/// The bay says this client is too old.
	case upgradeRequired(String)
	/// The answer was not valid Cryo API (bad HTTP, missing version header, undecodable body).
	case badResponse(String)
	/// `CRYO_URL` could not be used.
	case badTarget(String)

	public var description: String {
		switch self {
		case .transport(let target, let message):
			if target.hasPrefix("unix://") {
				return "no bay at \(target) — is `cryo bay` running? (\(message))"
			}
			return "cannot reach bay at \(target): \(message)"
		case .api(let e, _): return "\(e.code): \(e.message)"
		case .upgradeRequired(let m): return "this cryo is too old for the bay: \(m). Update cryo."
		case .badResponse(let m): return "unexpected response from bay: \(m)"
		case .badTarget(let m): return "bad CRYO_URL: \(m)"
		}
	}
}

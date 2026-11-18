import CryoAPI
import CryoClient
import CryoHTTP

/// Turning a bay's lease into the deck's: new id, `cryo-D7` host, and the ssh config written for D7.
public enum DeckRewrite {
	/// Replaces `from` with `to` where it stands alone (not inside a longer id such as L50 for L5).
	public static func replaceID(in text: String, from: String, to: String) -> String {
		let t = Array(text)
		let f = Array(from)
		guard !f.isEmpty, t.count >= f.count else { return text }
		func isWord(_ c: Character) -> Bool { c.isLetter || c.isNumber || c == "_" }
		var out = ""
		var i = 0
		while i < t.count {
			if i + f.count <= t.count, Array(t[i..<i + f.count]) == f,
				i == 0 || !isWord(t[i - 1]), i + f.count == t.count || !isWord(t[i + f.count])
			{
				out += to
				i += f.count
			} else {
				out.append(t[i])
				i += 1
			}
		}
		return out
	}

	/// `capsule`: the lease's number in the deck's status (`capsuleNumber`); nil keeps the bay's.
	public static func lease(_ l: Lease, from bayID: String, to deckID: String, capsule: Int? = nil) -> Lease {
		var r = l
		r.id = deckID
		if let capsule { r.capsule = capsule }
		r.ssh.host = replaceID(in: l.ssh.host, from: bayID, to: deckID)
		r.ssh.config = replaceID(in: l.ssh.config, from: bayID, to: deckID)
		return r
	}

	/// The deck's number for capsule `n` of a bay, as the deck's status numbers it: the bay's capsules
	/// come after the `offset` capsules of the bays before it, in the order the bay lists them. A bay's
	/// own numbers need not start at 0 (a bay can serve only capsule 1), so this is the capsule's
	/// position in `bayCapsules`, not `n` itself; a number the bay didn't list keeps `offset + n`.
	public static func capsuleNumber(_ n: Int, offset: Int, bayCapsules: [Int]) -> Int {
		offset + (bayCapsules.firstIndex(of: n) ?? n)
	}
}

/// The deck's lease numbers (`D<n>`), kept in a file so they keep counting up after a restart.
public final class LeaseCounter: @unchecked Sendable {
	private let path: String?
	private let lock = Monitor()
	private var value: Int

	/// `file` nil keeps the count in memory only (tests).
	public init(file: String? = nil, start: Int = 1) {
		path = file
		let stored = file.flatMap { readCounter($0) }
		value = max(stored ?? start, 1)
	}

	public func next() -> Int {
		lock.withLock {
			let n = value
			value += 1
			if let path { try? writeCounter(path, value) }
			return n
		}
	}
}

private func readCounter(_ path: String) -> Int? {
	readTextFile(path).flatMap { Int($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
}

private func writeCounter(_ path: String, _ n: Int) throws {
	try writeAtomically(path, "\(n)\n", mode: 0o600)
}

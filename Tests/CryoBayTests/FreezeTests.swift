import Foundation
import Testing

@testable import CryoBay

/// The staging swap shared by `cryo bay freeze`, the bay's refreeze and `cryo image use`.
@Suite struct FreezeTests {
	func scratch() throws -> BayPaths {
		let p = BayPaths(root: FileManager.default.temporaryDirectory.appending(path: "cryo-freeze-\(UUID().uuidString)", directoryHint: .isDirectory))
		try p.prepare()
		return p
	}

	func capsule(_ dir: URL, _ text: String) throws {
		try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
		try text.write(to: dir.appending(path: "manifest.json"), atomically: true, encoding: .utf8)
	}

	func text(_ c: CapsuleFiles) -> String? { try? String(contentsOf: c.manifest, encoding: .utf8) }

	func names(_ p: BayPaths) throws -> Set<String> { Set(try FileManager.default.contentsOfDirectory(atPath: p.capsules.path)) }

	@Test func swapReplacesTheLiveCapsulesAndLeavesNoLeftovers() throws {
		let p = try scratch()
		defer { try? FileManager.default.removeItem(at: p.root) }
		try capsule(p.capsule(0).dir, "old 0")
		let s0 = Freeze.staging("use", 0, paths: p)
		let s1 = Freeze.staging("use", 1, paths: p)
		try capsule(s0.dir, "new 0")
		try capsule(s1.dir, "new 1")
		try Freeze.swapIn([(s0.dir, p.capsule(0)), (s1.dir, p.capsule(1))], paths: p)
		#expect(text(p.capsule(0)) == "new 0" && text(p.capsule(1)) == "new 1")
		#expect(try names(p) == ["0", "1"])
	}

	/// A failed swap (here: the second staged capsule is missing) puts every capsule back as it was,
	/// so a failed `image use` keeps the old image serving.
	@Test func failedSwapRollsBack() throws {
		let p = try scratch()
		defer { try? FileManager.default.removeItem(at: p.root) }
		try capsule(p.capsule(0).dir, "old 0")
		try capsule(p.capsule(1).dir, "old 1")
		let s0 = Freeze.staging("use", 0, paths: p)
		let s1 = Freeze.staging("use", 1, paths: p)
		try capsule(s0.dir, "new 0")
		#expect(throws: (any Error).self) { try Freeze.swapIn([(s0.dir, p.capsule(0)), (s1.dir, p.capsule(1))], paths: p) }
		#expect(text(p.capsule(0)) == "old 0" && text(p.capsule(1)) == "old 1")
		#expect(try names(p) == ["0", "1", s0.dir.lastPathComponent])
	}

	/// A refreeze or `cryo bay freeze` that fails before the swap never touches the live capsule; the
	/// staging names carry this process's pid, so start-up cleanup knows whose they are.
	@Test func stagingIsBesideTheLiveCapsule() throws {
		let p = try scratch()
		defer { try? FileManager.default.removeItem(at: p.root) }
		let s = Freeze.staging("refreeze", 1, paths: p)
		#expect(s.number == 1 && s.dir.deletingLastPathComponent().lastPathComponent == "capsules")
		#expect(Leftovers.stagingOwner(s.dir.lastPathComponent) == getpid())
		#expect(s.dir.lastPathComponent.hasPrefix(".tmp-refreeze-1."))
	}
}

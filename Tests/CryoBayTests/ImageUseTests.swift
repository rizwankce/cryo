import Foundation
import Testing

@testable import CryoBay

@Suite struct ImageUseTests {
	static func image(_ digest: String, tag: String, xcode: String? = nil) -> ImageInfo {
		ImageInfo(digest: digest, tag: tag, macOS: "27.2 (26B123)", cpus: 4, memoryGB: 8, createdAt: Date(timeIntervalSince1970: 0), xcode: xcode)
	}

	/// Digest first, then tag, then a unique prefix; `abc` is a prefix of one digest and the tag of
	/// another, and the tag wins.
	@Test func resolvesDigestTagAndPrefix() throws {
		let images = [Self.image("abc111", tag: "xcode-27.2"), Self.image("abd222", tag: "abc"), Self.image("ff0000", tag: "macos-27.2")]
		#expect(try ImageRef.resolve("abd222", in: images) == "abd222")
		#expect(try ImageRef.resolve("macos-27.2", in: images) == "ff0000")
		#expect(try ImageRef.resolve("abc", in: images) == "abd222")
		#expect(try ImageRef.resolve("abc1", in: images) == "abc111")
		#expect(try ImageRef.resolve("f", in: images) == "ff0000")
		#expect(throws: BayError.self) { try ImageRef.resolve("ab", in: images) }  // two digests
		#expect(throws: BayError.self) { try ImageRef.resolve("zz", in: images) }
		#expect(throws: BayError.self) { try ImageRef.resolve("", in: images) }
		let twoTags = [Self.image("aa", tag: "t"), Self.image("bb", tag: "t")]
		#expect(throws: BayError.self) { try ImageRef.resolve("t", in: twoTags) }
	}

	/// Existing capsules keep their number and subnet (the guest IP is in the saved state); missing
	/// ones take the lowest free number and subnet, never the build VM's.
	@Test func plansCapsules() {
		let plain = Self.image("aa", tag: "macos-27.2")
		#expect(ImageUsePlan.make(existing: [0: 0, 1: 1], count: 2, image: plain).capsules == [.init(n: 0, subnet: 0), .init(n: 1, subnet: 1)])
		#expect(ImageUsePlan.make(existing: [1: 0], count: 2, image: plain).capsules == [.init(n: 0, subnet: 1), .init(n: 1, subnet: 0)])
		#expect(ImageUsePlan.make(existing: [0: 0, 1: 1, 2: 2], count: 2, image: plain).capsules.map(\.n) == [0, 1])
		#expect(ImageUsePlan.make(existing: [:], count: 1, image: plain).capsules == [.init(n: 0, subnet: 0)])
		let nine = Dictionary(uniqueKeysWithValues: (0..<9).map { ($0 + 1, $0) })
		#expect(ImageUsePlan.make(existing: nine, count: 10, image: plain).capsules.first == .init(n: 0, subnet: 10))
	}

	@Test func plansWarmUp() {
		let xcode = Self.image("aa", tag: "ci", xcode: "27.2 (27B52)")
		let plain = Self.image("bb", tag: "macos-27.2")
		#expect(ImageUsePlan.make(existing: [:], count: 1, image: xcode).warmUp == ["ios"])
		#expect(ImageUsePlan.make(existing: [:], count: 1, image: Self.image("cc", tag: "xcode-27.2")).warmUp == ["ios"])
		#expect(ImageUsePlan.make(existing: [:], count: 1, image: plain).warmUp == nil)
		#expect(ImageUsePlan.make(existing: [:], count: 1, image: xcode, warmUp: []).warmUp == nil)
		#expect(ImageUsePlan.make(existing: [:], count: 1, image: plain, warmUp: ["macos"]).warmUp == ["macos"])
	}

	/// A crashed `use` leaves staging directories; start-up cleanup must delete them, but not those
	/// of a `use` still running (start-up doesn't stop image commands).
	@Test func stagingIsCleanedAtStart() {
		let dead = [ImageUsePlan.staging(0, pid: 77), ImageUsePlan.staging(1, pid: 77)]
		let plan = Leftovers.refreezeRepairs(["0"] + dead + [ImageUsePlan.staging(0, pid: 88)], alive: { $0 == 88 })
		#expect(plan.delete.sorted() == dead)
		#expect(plan.restore.isEmpty)
		#expect(ImageUsePlan.staging(1, pid: 77) == ".tmp-use-1.77")
	}

	@Test func rmRefusesTheImageInUse() throws {
		let fm = FileManager.default
		let root = fm.temporaryDirectory.appending(path: "cryo-image-rm-\(UUID().uuidString)", directoryHint: .isDirectory)
		defer { try? fm.removeItem(at: root) }
		let paths = BayPaths(root: root)
		try paths.prepare()
		for (d, t) in [("aaaa1111", "xcode-27.2"), ("bbbb2222", "old"), ("cccc3333", "frozen")] {
			try fm.createDirectory(at: paths.image(d).dir, withIntermediateDirectories: true)
			try BayJSON.write(Self.image(d, tag: t), to: paths.image(d).info)
		}
		var config = BayConfig()
		config.image = "aaaa1111"
		try config.save(paths.config)
		// Capsule 0 still frozen on cccc3333 (e.g. a `use` that swapped only some capsules).
		try fm.createDirectory(at: paths.capsule(0).dir, withIntermediateDirectories: true)
		let m = CapsuleManifest(
			image: "cccc3333", cpus: 4, memoryGB: 8, mac: "x", network: CapsuleNetwork(subnet: 0), vsock: true, inputs: true,
			host: "h", files: [:], frozenAt: Date())
		try BayJSON.write(m, to: paths.capsule(0).manifest)

		var said = ""
		#expect(throws: BayError.self) { try ImageUse.rm(["xcode-27.2"], paths: paths, out: { said += $0 }) }
		#expect(throws: BayError.self) { try ImageUse.rm(["cccc"], paths: paths, out: { said += $0 }) }
		#expect(fm.fileExists(atPath: paths.image("aaaa1111").dir.path))
		#expect(fm.fileExists(atPath: paths.image("cccc3333").dir.path))
		#expect(try ImageUse.rm(["bbbb"], paths: paths, out: { said += $0 }) == 0)
		#expect(!fm.fileExists(atPath: paths.image("bbbb2222").dir.path))
		#expect(said == "removed image bbbb2222\n")
	}
}

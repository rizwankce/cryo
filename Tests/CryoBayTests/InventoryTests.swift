import Foundation
import Testing

@testable import CryoBay

/// `manifestProblems` (doctor, `cryo bay capsules`) and the thaw's `mismatches` must agree: doctor
/// saying "saved state matches" while every refill cold boots hides the problem.
@Suite struct InventoryTests {
	func scratch() throws -> BayPaths {
		let dir = FileManager.default.temporaryDirectory.appending(path: "cryo-inventory-\(UUID().uuidString)", directoryHint: .isDirectory)
		let p = BayPaths(root: dir)
		try p.prepare()
		return p
	}

	/// Image `digest` and capsule 1 on disk, frozen with `mac` in the manifest and `macFile` in mac.txt.
	func populate(_ p: BayPaths, digest: String = "d1", mac: String = "12:ab:cd:10:20:31", macFile: String = "12:AB:CD:10:20:31\n") throws -> CapsuleManifest {
		let fm = FileManager.default
		let image = p.image(digest)
		let capsule = p.capsule(1)
		try fm.createDirectory(at: image.dir, withIntermediateDirectories: true)
		try fm.createDirectory(at: capsule.dir, withIntermediateDirectories: true)
		for u in [image.base, image.hardwareModel, capsule.freezeLayer, capsule.machineID, capsule.state, capsule.aux] {
			try Data("x".utf8).write(to: u)
		}
		try macFile.write(to: capsule.mac, atomically: true, encoding: .utf8)
		let m = CapsuleManifest(
			image: digest, cpus: 4, memoryGB: 8, mac: mac, network: CapsuleNetwork(subnet: 1), vsock: true, inputs: true,
			host: Host.fingerprint(), files: CapsuleManifest.stamps(image: image, capsule: capsule), frozenAt: Date(timeIntervalSince1970: 0))
		try BayJSON.write(m, to: capsule.manifest)
		return m
	}

	/// Both views of capsule 1 against the configured `digest`.
	func views(_ p: BayPaths, _ m: CapsuleManifest, digest: String) -> (doctor: [String], thaw: [String]) {
		(
			manifestProblems(paths: p, capsule: 1, digest: digest),
			m.mismatches(image: p.image(digest), capsule: p.capsule(1), digest: digest)
		)
	}

	@Test func cleanCapsuleMatchesInBoth() throws {
		let p = try scratch()
		defer { try? FileManager.default.removeItem(at: p.root) }
		let m = try populate(p)
		let v = views(p, m, digest: "d1")
		#expect(v.doctor.isEmpty && v.thaw.isEmpty)
	}

	/// mac.txt written in another case is the same MAC: the thaw restores, so doctor says it matches.
	@Test func macCaseIsIgnoredByBoth() throws {
		let p = try scratch()
		defer { try? FileManager.default.removeItem(at: p.root) }
		let m = try populate(p, mac: "12:AB:CD:10:20:31", macFile: "12:ab:cd:10:20:31")
		let v = views(p, m, digest: "d1")
		#expect(v.doctor.isEmpty && v.thaw.isEmpty)
	}

	/// A capsule frozen on another image than the configured one cold boots; doctor must say so.
	@Test func otherConfiguredImageFailsBoth() throws {
		let p = try scratch()
		defer { try? FileManager.default.removeItem(at: p.root) }
		let m = try populate(p)
		// d2's files exist too, with d1's stamps; only the digest differs.
		try FileManager.default.copyItem(at: p.image("d1").dir, to: p.image("d2").dir)
		let v = views(p, m, digest: "d2")
		#expect(v.thaw.contains { $0.hasPrefix("image:") })
		#expect(v.doctor.contains { $0.hasPrefix("image:") })
		// Without a digest, manifestProblems reads the configured image from config.toml.
		var config = BayConfig()
		config.image = "d2"
		try config.save(p.config)
		#expect(manifestProblems(paths: p, capsule: 1).contains { $0.hasPrefix("image:") })
	}

	@Test func changedFilesFailBoth() throws {
		let p = try scratch()
		defer { try? FileManager.default.removeItem(at: p.root) }
		let m = try populate(p)
		try Data("longer".utf8).write(to: p.capsule(1).freezeLayer)
		try "aa:bb:cc:dd:ee:ff".write(to: p.capsule(1).mac, atomically: true, encoding: .utf8)
		let v = views(p, m, digest: "d1")
		#expect(v.thaw.contains { $0.hasPrefix("freeze-layer:") } && v.thaw.contains { $0.hasPrefix("mac:") })
		#expect(Set(v.thaw).isSubset(of: Set(v.doctor)))
	}

	/// What only doctor adds: files a restore needs that the stamps don't cover.
	@Test func missingStateIsReported() throws {
		let p = try scratch()
		defer { try? FileManager.default.removeItem(at: p.root) }
		_ = try populate(p)
		try FileManager.default.removeItem(at: p.capsule(1).state)
		#expect(manifestProblems(paths: p, capsule: 1, digest: "d1") == ["state.vzstate missing"])
	}
}

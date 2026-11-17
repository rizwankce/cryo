import Foundation
import Testing

@testable import CryoBay

@Suite struct BayTokenTests {
	private func tempPaths() throws -> BayPaths {
		let d = FileManager.default.temporaryDirectory.appending(path: "cryo-tok-\(UUID().uuidString)", directoryHint: .isDirectory)
		try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
		return BayPaths(root: d)
	}

	@Test func tokenLivesInTheBayRoot() throws {
		let paths = try tempPaths()
		defer { try? FileManager.default.removeItem(at: paths.root) }
		#expect(BayToken.load(paths) == nil)
		let t = try BayToken.create(paths)
		#expect(FileManager.default.fileExists(atPath: paths.root.appending(path: "token").path))
		#expect(BayToken.load(paths) == t)
		#expect(try BayToken.create(paths) == t)
		#expect(try BayToken.create(paths, rotate: true) != t)
	}

	@Test func commandPrintsTheToken() throws {
		let paths = try tempPaths()
		defer { try? FileManager.default.removeItem(at: paths.root) }
		nonisolated(unsafe) var out = ""
		#expect(try BayToken.command([], paths: paths, out: { out += $0 }) == 0)
		let first = out.trimmingCharacters(in: .whitespacesAndNewlines)
		#expect(first == BayToken.load(paths))
		out = ""
		_ = try BayToken.command(["--rotate"], paths: paths, out: { out += $0 })
		#expect(out.trimmingCharacters(in: .whitespacesAndNewlines) != first)
	}
}

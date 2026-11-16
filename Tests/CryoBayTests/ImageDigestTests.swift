import CryptoKit
import Foundation
import Testing

@testable import CryoBay

@Suite struct ImageDigestTests {
	/// SHA-256 over hardware-model.bin then base.asif, first 16 hex chars; the same off the main actor.
	@Test func digestIsTheHashOfBothFilesInOrder() async throws {
		let dir = FileManager.default.temporaryDirectory.appending(path: "cryo-digest-\(UUID().uuidString)", directoryHint: .isDirectory)
		try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
		defer { try? FileManager.default.removeItem(at: dir) }
		let hw = dir.appending(path: "hardware-model.bin")
		let base = dir.appending(path: "base.asif")
		try Data("model".utf8).write(to: hw)
		// More than one read chunk, so the chunked reads are covered.
		let big = Data(repeating: 7, count: ImageDigest.chunk + 123)
		try big.write(to: base)
		let want = String(SHA256.hash(data: Data("model".utf8) + big).map { String(format: "%02x", $0) }.joined().prefix(16))
		#expect(try ImageDigest.compute(hardwareModel: hw, base: base) == want)
		#expect(try await ImageDigest.offMain(hardwareModel: hw, base: base) == want)
	}
}

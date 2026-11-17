import CryoAPI
import CryoClient
import CryoDeck
import Foundation
import Testing

@Suite struct RewriteTests {
	@Test func replacesAnIDThatStandsAlone() {
		#expect(DeckRewrite.replaceID(in: "cryo ssh L5", from: "L5", to: "D7") == "cryo ssh D7")
		#expect(DeckRewrite.replaceID(in: "Host cryo-L5\n", from: "L5", to: "D7") == "Host cryo-D7\n")
		#expect(DeckRewrite.replaceID(in: "~/.cryo/keys/L5", from: "L5", to: "D7") == "~/.cryo/keys/D7")
		#expect(DeckRewrite.replaceID(in: "keys/L5.pub", from: "L5", to: "D7") == "keys/D7.pub")
		#expect(DeckRewrite.replaceID(in: "L5", from: "L5", to: "D7") == "D7")
		#expect(DeckRewrite.replaceID(in: "L5 L5\nL5", from: "L5", to: "D7") == "D7 D7\nD7")
	}

	@Test func leavesLongerIDsAndWordsAlone() {
		#expect(DeckRewrite.replaceID(in: "cryo-L50 L5", from: "L5", to: "D7") == "cryo-L50 D7")
		#expect(DeckRewrite.replaceID(in: "L5x xL5 L5_ _L5 L55", from: "L5", to: "D7") == "L5x xL5 L5_ _L5 L55")
		#expect(DeckRewrite.replaceID(in: "FakeHostKeyL5", from: "L5", to: "D7") == "FakeHostKeyL5")
	}

	@Test func emptyAndShortInputsAreUnchanged() {
		#expect(DeckRewrite.replaceID(in: "", from: "L5", to: "D7") == "")
		#expect(DeckRewrite.replaceID(in: "L", from: "L5", to: "D7") == "L")
		#expect(DeckRewrite.replaceID(in: "abc", from: "", to: "D7") == "abc")
	}

	private func sample(_ id: String = "L1", capsule: Int = 0) -> Lease {
		let now = Date(timeIntervalSince1970: 1_800_000_000)
		return Lease(
			id: id, name: "job", capsule: capsule, state: "leased", createdAt: now, renewBy: now.addingTimeInterval(60),
			expiresAt: now.addingTimeInterval(3600), cache: "app", idleS: 300,
			ssh: SSHInfo(
				user: "cryo", host: "cryo-\(id)", key: "KEY-\(id)",
				config: """
					Host cryo-\(id)
					  User cryo
					  ProxyCommand cryo ssh \(id)
					  IdentityFile ~/.cryo/keys/\(id)
					  HostKeyAlias cryo-\(id)
					  UserKnownHostsFile ~/.cryo/known_hosts/\(id)
					  StrictHostKeyChecking yes
					""",
				hostKey: "ssh-ed25519 AAAAFakeHostKey\(id)"))
	}

	@Test func leaseGetsTheDeckIDEverywhere() {
		let r = DeckRewrite.lease(sample(), from: "L1", to: "D7")
		#expect(r.id == "D7")
		#expect(r.ssh.host == "cryo-D7")
		#expect(r.ssh.config.contains("Host cryo-D7\n"))
		#expect(r.ssh.config.contains("ProxyCommand cryo ssh D7\n"))
		#expect(r.ssh.config.contains("IdentityFile ~/.cryo/keys/D7\n"))
		#expect(r.ssh.config.contains("HostKeyAlias cryo-D7\n"))
		#expect(r.ssh.config.contains("UserKnownHostsFile ~/.cryo/known_hosts/D7\n"))
		#expect(!r.ssh.config.contains("L1"))
	}

	@Test func keysAndOtherFieldsPassThrough() {
		let l = sample()
		let r = DeckRewrite.lease(l, from: "L1", to: "D7")
		// The host key and private key are the bay's, even when they end in the old id.
		#expect(r.ssh.key == l.ssh.key)
		#expect(r.ssh.hostKey == l.ssh.hostKey)
		#expect(r.ssh.user == "cryo")
		#expect(r.name == "job" && r.cache == "app" && r.idleS == 300 && r.state == "leased")
		#expect(r.createdAt == l.createdAt && r.renewBy == l.renewBy && r.expiresAt == l.expiresAt)
	}

	@Test func capsuleOffsetShiftsTheCapsuleNumber() {
		#expect(DeckRewrite.lease(sample(capsule: 1), from: "L1", to: "D2", capsuleOffset: 2).capsule == 3)
		#expect(DeckRewrite.lease(sample(capsule: 1), from: "L1", to: "D2").capsule == 1)
	}

	@Test func aLongerBayIDIsNotHalfReplaced() {
		let r = DeckRewrite.lease(sample("L10"), from: "L10", to: "D3")
		#expect(r.ssh.host == "cryo-D3")
		#expect(!r.ssh.config.contains("L10") && !r.ssh.config.contains("D30"))
	}
}

@Suite struct LeaseCounterTests {
	private func tempFile() throws -> (dir: String, file: String) {
		let dir = try makeTempDir()
		return (dir, dir + "/deck-next-lease")
	}

	@Test func countsUpFromOneInMemory() {
		let c = LeaseCounter()
		let got: [Int] = [c.next(), c.next(), c.next()]
		#expect(got == [1, 2, 3])
	}

	@Test func startValueIsUsedWhenThereIsNoFile() throws {
		let (dir, file) = try tempFile()
		defer { try? FileManager.default.removeItem(atPath: dir) }
		let c = LeaseCounter(file: file, start: 5)
		#expect(c.next() == 5)
	}

	@Test func theNextNumberIsKeptInTheFile() throws {
		let (dir, file) = try tempFile()
		defer { try? FileManager.default.removeItem(atPath: dir) }
		let c = LeaseCounter(file: file)
		let got: [Int] = [c.next(), c.next(), c.next()]
		#expect(got == [1, 2, 3])
		#expect(readTextFile(file) == "4\n")
		#expect(fileMode(file) == 0o600)
	}

	@Test func aNewCounterContinuesWhereTheOldOneStopped() throws {
		let (dir, file) = try tempFile()
		defer { try? FileManager.default.removeItem(atPath: dir) }
		let first = LeaseCounter(file: file)
		_ = first.next()
		_ = first.next()
		let second = LeaseCounter(file: file)
		#expect(second.next() == 3)
		#expect(second.next() == 4)
	}

	@Test func aBrokenFileStartsOverAndZeroIsNotUsed() throws {
		let (dir, file) = try tempFile()
		defer { try? FileManager.default.removeItem(atPath: dir) }
		try "not a number\n".write(toFile: file, atomically: true, encoding: .utf8)
		#expect(LeaseCounter(file: file).next() == 1)
		try "0\n".write(toFile: file, atomically: true, encoding: .utf8)
		#expect(LeaseCounter(file: file).next() == 1)
	}

	@Test func concurrentCallersNeverShareANumber() async {
		let c = LeaseCounter()
		let numbers = await withTaskGroup(of: [Int].self) { group in
			for _ in 0..<8 { group.addTask { (0..<50).map { _ in c.next() } } }
			var all: [Int] = []
			for await part in group { all += part }
			return all
		}
		#expect(Set(numbers).count == 400)
		#expect(numbers.min() == 1 && numbers.max() == 400)
	}
}

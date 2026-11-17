import Testing

@testable import CryoBay

@Suite("Bay subcommand arguments")
struct BayCommandTests {
	@Test func helpPrintsUsageWithoutRunning() throws {
		for name in ["lease-test", "thaw-test"] {
			let sub = try #require(BayCommand.subcommands[name])
			for flag in ["--help", "-h"] {
				guard case .help(let text) = BayCommand.check(name, sub, [flag]) else {
					Issue.record("\(name) \(flag) did not print help")
					continue
				}
				#expect(text.hasPrefix("usage: cryo bay \(name)"))
			}
			// Help wins even next to other flags.
			guard case .help = BayCommand.check(name, sub, ["--runs", "1", "--help"]) else {
				Issue.record("\(name) --help after other flags did not print help")
				continue
			}
		}
	}

	@Test func everySubcommandHasHelp() {
		for (name, sub) in BayCommand.subcommands {
			guard case .help(let text) = BayCommand.check(name, sub, ["--help"]) else {
				Issue.record("\(name) --help did not print help")
				continue
			}
			#expect(text.contains(sub.summary))
		}
	}

	@Test func unknownFlagsAreRejected() throws {
		let sub = try #require(BayCommand.subcommands["lease-test"])
		guard case .reject(let text) = BayCommand.check("lease-test", sub, ["--bogus"]) else {
			Issue.record("unknown flag was not rejected")
			return
		}
		#expect(text.contains("unknown option --bogus"))
		#expect(BayCommand.check("lease-test", sub, ["--runs", "2", "--queue"]) == .run)
		let paths = try #require(BayCommand.subcommands["paths"])
		#expect(BayCommand.check("paths", paths, []) == .run)
	}
}

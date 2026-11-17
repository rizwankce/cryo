import CryoServer
import Foundation
import Testing

@testable import CryoBay

@Suite struct ConfigTests {
	@Test func defaultsWhenEmpty() throws {
		#expect(try BayConfig.parse("") == BayConfig())
	}

	@Test func parsesKnownKeysAndComments() throws {
		let c = try BayConfig.parse(
			"""
			# comment
			image = "abc123"   # trailing
			idle_timeout_s = 120
			capsules = 1
			ignore_doctor = true
			""")
		#expect(c.image == "abc123")
		#expect(c.idleTimeoutS == 120)
		#expect(c.capsules == 1)
		#expect(c.maxLeaseS == 86400)
		#expect(c.ignoreDoctor)
		#expect(try !BayConfig.parse("ignore_doctor = false").ignoreDoctor)
		#expect(!BayConfig().ignoreDoctor)
	}

	@Test func parsesListen() throws {
		#expect(try BayConfig.parse("").listen == nil)
		#expect(try BayConfig.parse("listen = \":7477\"").listen == ":7477")
		#expect(try BayConfig.parse("listen = \"7477\"  # all interfaces").listen == "7477")
		#expect(try BayConfig.parse("listen = \"10.0.0.2:7477\"").listen == "10.0.0.2:7477")
	}

	@Test func rejectsBadListen() {
		#expect(throws: BayError.self) { try BayConfig.parse("listen = :7477") }  // not quoted
		#expect(throws: BayError.self) { try BayConfig.parse("listen = 7477") }
		#expect(throws: BayError.self) { try BayConfig.parse("listen = \"\"") }
		#expect(throws: BayError.self) { try BayConfig.parse("listen = \"host:port\"") }
		#expect(throws: BayError.self) { try BayConfig.parse("listen = \":70000\"") }
	}

	@Test func listenRoundTripsAndShowsInConfigOutput() throws {
		var c = BayConfig()
		c.listen = ":7477"
		#expect(c.text().contains("listen = \":7477\"\n"))
		#expect(try BayConfig.parse(c.text()) == c)
		#expect(!BayConfig().text().contains("listen"))
	}

	@Test func listenFlagWinsOverConfig() throws {
		var c = BayConfig()
		#expect(c.listener(flag: nil) == nil)
		let flag = BayServer.parseListen("10.0.0.2:9000")
		#expect(c.listener(flag: flag)?.port == 9000)
		c.listen = ":7477"
		#expect(c.listener(flag: nil)?.host == "0.0.0.0")
		#expect(c.listener(flag: nil)?.port == 7477)
		#expect(c.listener(flag: flag)?.host == "10.0.0.2")
		#expect(c.listener(flag: flag)?.port == 9000)
	}

	@Test func rejectsBadInput() {
		#expect(throws: BayError.self) { try BayConfig.parse("nope = 1") }
		#expect(throws: BayError.self) { try BayConfig.parse("capsules = 3") }
		#expect(throws: BayError.self) { try BayConfig.parse("image = abc") }
		#expect(throws: BayError.self) { try BayConfig.parse("idle_timeout_s = -5") }
		#expect(throws: BayError.self) { try BayConfig.parse("ignore_doctor = yes") }
		#expect(throws: BayError.self) { try BayConfig.parse("ignore_doctor = \"true\"") }
	}

	@Test func roundTrips() throws {
		var c = BayConfig()
		c.image = "d1"
		c.waitDefaultS = 30
		#expect(try BayConfig.parse(c.text()) == c)
		#expect(!c.text().contains("ignore_doctor"))  // a new config.toml doesn't offer the escape hatch
		c.ignoreDoctor = true
		#expect(try BayConfig.parse(c.text()) == c)
	}

	@Test func pathsLayout() {
		let p = BayPaths(root: URL(filePath: "/tmp/cryo-test", directoryHint: .isDirectory))
		#expect(p.capsule(1).state.path == "/tmp/cryo-test/capsules/1/state.vzstate")
		#expect(p.image("d1").base.path == "/tmp/cryo-test/images/d1/base.asif")
		#expect(p.lease("L1").folder.path == "/tmp/cryo-test/leases/L1/folder")
		#expect(p.cache("app").path == "/tmp/cryo-test/caches/app.asif")
		#expect(CapsuleNetwork(subnet: 2).guestIP == "10.77.2.2")
		#expect(
			CapsuleNetwork(subnet: 2).staticIPCommand
				== "sudo -n networksetup -setmanual Ethernet 10.77.2.2 255.255.255.0 10.77.2.1 && sudo -n networksetup -setdnsservers Ethernet 10.77.2.1")
	}
}

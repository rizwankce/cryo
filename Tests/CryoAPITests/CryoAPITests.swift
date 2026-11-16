import Testing

@testable import CryoAPI

#if canImport(FoundationEssentials)
	import FoundationEssentials
#else
	import Foundation
#endif

private let leaseJSON = """
	{
	  "id": "L81", "name": "fix-login", "capsule": 0, "state": "leased",
	  "created_at": "2026-11-05T21:10:00Z", "renew_by": "2026-11-05T21:15:00Z",
	  "expires_at": "2026-11-06T21:10:00Z", "cache": "app",
	  "ssh": {
	    "user": "cryo", "host": "cryo-L81",
	    "key": "-----BEGIN OPENSSH PRIVATE KEY-----…",
	    "config": "Host cryo-L81\\n  User cryo\\n  ProxyCommand cryo ssh L81\\n  IdentityFile ~/.cryo/keys/L81\\n  HostKeyAlias cryo-L81\\n  UserKnownHostsFile ~/.cryo/known_hosts/L81\\n  GlobalKnownHostsFile /dev/null\\n  StrictHostKeyChecking yes",
	    "host_key": "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAI…"
	  }
	}
	"""

@Suite struct CryoAPITests {
	@Test func decodesSpecLeaseExample() throws {
		let lease = try CryoJSON.decoder().decode(Lease.self, from: Data(leaseJSON.utf8))
		#expect(lease.id == "L81")
		#expect(lease.name == "fix-login")
		#expect(lease.capsule == 0)
		#expect(lease.cache == "app")
		#expect(lease.ssh.host == "cryo-L81")
		#expect(lease.ssh.config.hasPrefix("Host cryo-L81\n  User cryo"))
		#expect(lease.ssh.hostKey == "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAI…")
		#expect(lease.createdAt == Date(timeIntervalSince1970: 1_793_913_000))
		#expect(lease.renewBy.timeIntervalSince(lease.createdAt) == 300)
		#expect(lease.expiresAt.timeIntervalSince(lease.createdAt) == 86400)
	}

	@Test func leaseRoundTripUsesSnakeCaseAndISODates() throws {
		let lease = try CryoJSON.decoder().decode(Lease.self, from: Data(leaseJSON.utf8))
		let data = try CryoJSON.encoder().encode(lease)
		let text = String(decoding: data, as: UTF8.self)
		#expect(text.contains("\"created_at\":\"2026-11-05T21:10:00Z\""))
		#expect(text.contains("\"expires_at\""))
		#expect(!text.contains("createdAt"))
		#expect(text.contains("\"host_key\":"))
		#expect(try CryoJSON.decoder().decode(Lease.self, from: data) == lease)
	}

	@Test func optionalFieldsAreOmitted() throws {
		let text = String(decoding: try CryoJSON.encoder().encode(LeaseRequest(waitS: 0)), as: UTF8.self)
		#expect(text == "{\"wait_s\":0}")
		let full = LeaseRequest(folder: "/r", cache: "app", waitS: 5, name: "x", idleS: 60)
		let t2 = String(decoding: try CryoJSON.encoder().encode(full), as: UTF8.self)
		#expect(t2 == "{\"cache\":\"app\",\"folder\":\"/r\",\"idle_s\":60,\"name\":\"x\",\"wait_s\":5}")
	}

	@Test func restartNoteRoundTrip() {
		let t = RestartNote.text(alert: "subnets taken", now: 1000)
		#expect(RestartNote.parse(t, now: 1010) == "subnets taken")
		#expect(RestartNote.parse(t, now: 1000 + RestartNote.maxAgeS) == nil)
		#expect(RestartNote.parse("garbage", now: 1000) == nil)
		#expect(RestartNote.parse("1000\n\n", now: 1000) == nil)
	}

	@Test func errorEnvelope() throws {
		let e = APIError(code: APIError.noCapacity, message: "full")
		let text = String(decoding: try CryoJSON.encoder().encode(e), as: UTF8.self)
		#expect(text == "{\"error\":{\"code\":\"no_capacity\",\"message\":\"full\"}}")
		let back = try CryoJSON.decoder().decode(APIError.self, from: Data(text.utf8))
		#expect(back == e)
		#expect(APIError.leaseLost == "lease_lost")
	}

	@Test func renewAndStatus() throws {
		let r = try CryoJSON.decoder().decode(RenewResponse.self, from: Data(#"{"renew_by":"2026-11-05T21:15:00Z"}"#.utf8))
		#expect(r.renewBy == Date(timeIntervalSince1970: 1_793_913_300))
		let s = Status(
			bay: .init(version: "0.1", image: "d", doctor: "ok"), capsules: [.init(n: 0, state: "leased", lease: "L1"), .init(n: 1, state: "thawed")], queue: 2)
		let data = try CryoJSON.encoder().encode(s)
		#expect(try CryoJSON.decoder().decode(Status.self, from: data) == s)
		#expect(apiVersion == 1 && apiVersionHeader == "Cryo-Api-Version")
	}

	@Test func unknownDoctorValueIsNotOK() throws {
		let s = try CryoJSON.decoder().decode(Status.self, from: Data(#"{"bay":{"version":"0.2","image":"d","doctor":"warn"},"capsules":[],"queue":0}"#.utf8))
		#expect(s.bay.doctor == "warn" && !s.bay.doctorOK)
		// A bay from before `health` and `blocked_by` were added still decodes.
		#expect(s.health == nil)
		#expect(s.bay.blockedBy == nil)
	}

	@Test func statusBlockedByWire() throws {
		let s = try CryoJSON.decoder().decode(
			Status.self,
			from: Data(
				#"{"bay":{"version":"0.2","image":"d","doctor":"failing","blocked_by":["screen unlocked"]},"capsules":[{"n":1,"state":"frozen"}],"queue":0}"#
					.utf8))
		#expect(s.bay.blockedBy == ["screen unlocked"] && !s.bay.doctorOK)
		// Omitted, not null, once the bay may thaw.
		let open = String(decoding: try CryoJSON.encoder().encode(Status.Bay(version: "0.2", image: "d", doctor: "ok")), as: UTF8.self)
		#expect(!open.contains("blocked_by"))
	}

	@Test func statusHealthWire() throws {
		let text =
			#"{"bay":{"version":"0.2","image":"d","doctor":"ok"},"capsules":[],"queue":0,"health":{"uptime_s":60,"host_uptime_s":4500000,"disk_free_bytes":120000000000,"thermal":"fair","leases_served":7,"leases_failed":1,"leases_expired":2,"refills":8,"refills_failed":3,"last_lease_ms":812}}"#
		let h = try #require(try CryoJSON.decoder().decode(Status.self, from: Data(text.utf8)).health)
		#expect(
			h
				== Status.Health(
					uptimeS: 60, hostUptimeS: 4_500_000, diskFreeBytes: 120_000_000_000, thermal: "fair", leasesServed: 7,
					leasesFailed: 1, leasesExpired: 2, refills: 8, refillsFailed: 3, lastLeaseMS: 812, lastRefillMS: nil))
	}

	@Test func jsonValueRoundTrip() throws {
		let text = #"{"a":[1,2.5,null,true,"s"],"b":{"c":false}}"#
		let v = try CryoJSON.decoder().decode(JSONValue.self, from: Data(text.utf8))
		#expect(v == .object(["a": .array([.number(1), .number(2.5), .null, .bool(true), .string("s")]), "b": .object(["c": .bool(false)])]))
		let again = try CryoJSON.decoder().decode(JSONValue.self, from: try CryoJSON.encoder().encode(v))
		#expect(again == v)
	}
}

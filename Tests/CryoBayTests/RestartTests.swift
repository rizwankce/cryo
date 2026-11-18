import CryoAPI
import Foundation
import Testing

@testable import CryoBay

@MainActor @Suite struct RestartTests {
	static func status(_ version: String, leases: [String?] = []) -> Status {
		Status(
			bay: .init(version: version, image: "img", doctor: "ok"),
			capsules: leases.enumerated().map { .init(n: $0.offset + 1, state: $0.element == nil ? "thawed" : "leased", lease: $0.element) },
			queue: 0)
	}

	@Test func refusesWhileLeasesRunUnlessForced() {
		#expect(BayRestart.decide(leases: [], force: false) == .restart)
		#expect(BayRestart.decide(leases: ["L12"], force: true) == .restart)
		#expect(
			BayRestart.decide(leases: ["L12", "L13"], force: false)
				== .refuse("2 lease(s) running (L12, L13); a restart ends them. Wait, or pass --force."))
		#expect(BayRestart.leaseIDs(Self.status("0.1.3", leases: ["L1", nil, "L2"])) == ["L1", "L2"])
		#expect(BayRestart.summary(old: nil, new: "0.2.0") == "bay restarted: not running → 0.2.0")
	}

	@Test func notInstalledPointsToInstall() async {
		var failure = ""
		do { _ = try await BayRestart.perform(force: false, installed: false, out: { _ in }, status: { nil }, kickstart: { (0, "") }, pause: {}) } catch {
			failure = "\(error)"
		}
		#expect(failure.contains("cryo bay install"))
	}

	@Test func leasedBayIsNotKicked() async {
		nonisolated(unsafe) var kicked = false
		do {
			_ = try await BayRestart.perform(
				force: false, installed: true, out: { _ in }, status: { Self.status("0.1.3", leases: ["L12"]) },
				kickstart: {
					kicked = true
					return (0, "")
				}, pause: {})
		} catch {}
		#expect(!kicked)
	}

	@Test func restartWaitsForTheNewBayAndReportsVersions() async throws {
		nonisolated(unsafe) var answers = [Self.status("0.1.3"), nil, nil, Self.status("0.2.0")]
		nonisolated(unsafe) var text = ""
		let code = try await BayRestart.perform(
			force: false, installed: true, out: { text += $0 }, status: { answers.isEmpty ? nil : answers.removeFirst() },
			kickstart: { (0, "") }, pause: {})
		#expect(code == 0)
		#expect(text == "bay restarted: 0.1.3 → 0.2.0\n")
	}

	@Test func silentBayAfterRestartFails() async {
		var failed = false
		do { _ = try await BayRestart.perform(force: true, installed: true, polls: 3, out: { _ in }, status: { nil }, kickstart: { (0, "") }, pause: {}) } catch
		{
			failed = true
		}
		#expect(failed)
	}
}

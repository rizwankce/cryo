import Foundation
import Testing
import Virtualization

@testable import CryoBay

@Suite struct VMTests {
	func scratch() throws -> BayPaths {
		let dir = FileManager.default.temporaryDirectory.appending(path: "cryo-vmtests-\(UUID().uuidString)", directoryHint: .isDirectory)
		let p = BayPaths(root: dir)
		try p.prepare()
		return p
	}

	func manifest(for capsule: CapsuleFiles, image: ImageFiles, digest: String = "d1") -> CapsuleManifest {
		CapsuleManifest(
			image: digest, cpus: 4, memoryGB: 8, mac: "12:ab:cd:10:20:31", network: CapsuleNetwork(subnet: 3), vsock: true,
			inputs: true, host: Host.fingerprint(), files: CapsuleManifest.stamps(image: image, capsule: capsule),
			frozenAt: Date(timeIntervalSince1970: 0))
	}

	func populate(_ image: ImageFiles, _ capsule: CapsuleFiles) throws {
		try FileManager.default.createDirectory(at: image.dir, withIntermediateDirectories: true)
		try FileManager.default.createDirectory(at: capsule.dir, withIntermediateDirectories: true)
		for u in [image.base, image.hardwareModel, capsule.freezeLayer, capsule.machineID] { try Data("x".utf8).write(to: u) }
		try "12:AB:CD:10:20:31\n".write(to: capsule.mac, atomically: true, encoding: .utf8)
	}

	@Test func cleanManifestHasNoMismatches() throws {
		let p = try scratch()
		defer { try? FileManager.default.removeItem(at: p.root) }
		let image = p.image("d1")
		let capsule = p.capsule(1)
		try populate(image, capsule)
		#expect(manifest(for: capsule, image: image).mismatches(image: image, capsule: capsule, digest: "d1").isEmpty)
	}

	@Test func changedFilesAndIdentityAreReported() throws {
		let p = try scratch()
		defer { try? FileManager.default.removeItem(at: p.root) }
		let image = p.image("d1")
		let capsule = p.capsule(1)
		try populate(image, capsule)
		var m = manifest(for: capsule, image: image)
		try Data("longer".utf8).write(to: image.base)
		try "aa:bb:cc:dd:ee:ff".write(to: capsule.mac, atomically: true, encoding: .utf8)
		m.host = "other host"
		let why = m.mismatches(image: image, capsule: capsule, digest: "d2").joined(separator: "\n")
		#expect(why.contains("base:"))
		#expect(why.contains("mac:"))
		#expect(why.contains("host:"))
		#expect(why.contains("image:"))
		#expect(!why.contains("machine-id:"))
	}

	@Test func missingFreezeLayerIsReported() throws {
		let p = try scratch()
		defer { try? FileManager.default.removeItem(at: p.root) }
		let image = p.image("d1")
		let capsule = p.capsule(1)
		try populate(image, capsule)
		let m = manifest(for: capsule, image: image)
		try FileManager.default.removeItem(at: capsule.freezeLayer)
		#expect(m.mismatches(image: image, capsule: capsule, digest: "d1").contains { $0.hasPrefix("freeze-layer:") })
	}

	@Test func specComesFromManifest() {
		let p = BayPaths(root: URL(filePath: "/tmp/cryo-spec", directoryHint: .isDirectory))
		let image = p.image("d1")
		let capsule = p.capsule(1)
		let m = manifest(for: capsule, image: image)
		let lease = p.lease("l1")
		let spec = VMSpec(image: image, capsule: capsule, manifest: m, aux: lease.aux, emptyShare: p.emptyShare)
		#expect(spec.subnet == 3 && spec.cpus == 4 && spec.memoryGB == 8 && spec.vsock && spec.inputs)
		#expect(spec.aux == lease.aux && spec.machineID == capsule.machineID && spec.hardwareModel == image.hardwareModel)
	}

	/// A thaw that fails before a VM runs leaves no lease directory: a capsule stuck on a taken
	/// subnet retries every minute and leaked an aux clone and an overlay each time.
	@Test @MainActor func failedThawRemovesTheLeaseDirectory() async throws {
		let p = try scratch()
		defer { try? FileManager.default.removeItem(at: p.root) }
		let image = p.image("d1")
		let capsule = p.capsule(1)
		try populate(image, capsule)
		let m = manifest(for: capsule, image: image)
		// No aux.img: the clone fails.
		await #expect(throws: (any Error).self) {
			_ = try await CapsuleVM.thaw(paths: p, image: image, digest: "d1", capsule: capsule, manifest: m, leaseID: "l1")
		}
		#expect(!FileManager.default.fileExists(atPath: p.lease("l1").dir.path))
		// Aux there, but the disks and hardware model aren't real: building the VM fails, on the
		// restore path (manifest matches) and on the cold boot path (it doesn't).
		try Data("x".utf8).write(to: capsule.aux)
		for digest in ["d1", "d2"] {
			await #expect(throws: (any Error).self) {
				_ = try await CapsuleVM.thaw(paths: p, image: image, digest: digest, capsule: capsule, manifest: m, leaseID: "l2")
			}
			#expect(!FileManager.default.fileExists(atPath: p.lease("l2").dir.path))
		}
	}

	@Test func clockCommandFormatsUTC() {
		let cmd = Guest.clockCommand(now: Date(timeIntervalSince1970: 1_793_830_407))
		#expect(cmd == "sudo -n date -u 110422132026.27 >/dev/null")
	}

	@Test func sshUsesTheFastOptionsAndImageKey() {
		let g = Guest(ip: "10.77.3.2", key: URL(filePath: "/k/id"))
		let a = g.sshArguments()
		#expect(Array(a.prefix(2)) == ["-F", "/dev/null"])
		#expect(a.contains("IdentityAgent=none") && a.contains("GSSAPIAuthentication=no"))
		#expect(a.contains("/k/id") && a.last == "cryo@10.77.3.2")
	}

	@Test func closedPortIsNotOpen() {
		#expect(!Guest.portOpen("127.0.0.1", 1, timeoutMs: 50))
	}

	@Test @MainActor func waitForTimesOut() async throws {
		await #expect(throws: BayError.self) { try await waitFor("never", timeout: 0.1, every: 0.02) { false } }
		var n = 0
		try await waitFor("third try", timeout: 2, every: 0.01) {
			n += 1
			return n == 3
		}
		#expect(n == 3)
	}

	@Test func runProcessCapturesOutputAndStatus() async {
		let r = await runProcess("/bin/sh", ["-c", "cat; echo err >&2; exit 3"], stdin: Data("in\n".utf8))
		#expect(r.status == 3 && r.out == "in\nerr\n")
	}

	/// More output than the pipe buffer (~64 KB) used to block the child on write forever.
	@Test(.timeLimit(.minutes(1))) func runProcessDrainsLargeOutput() async {
		let r = await runProcess("/bin/sh", ["-c", "head -c 200000 /dev/zero | tr '\\0' x; head -c 100000 /dev/zero | tr '\\0' y >&2; exit 4"])
		#expect(r.status == 4)
		#expect(r.out.filter { $0 == "x" }.count == 200_000 && r.out.filter { $0 == "y" }.count == 100_000)
	}

	@Test func runForegroundReturnsTheExitStatus() async {
		#expect(await runForeground("/bin/sh", ["-c", "exit 7"]) == 7)
		#expect(await runForeground("/usr/bin/true", []) == 0)
		#expect(await runForeground("/bin/sh", ["-c", "kill -KILL $$"]) == 128 + SIGKILL)
	}

	/// A guest that stops answering mid-login left a refill waiting forever.
	@Test(.timeLimit(.minutes(1))) func runProcessStopsAHungChild() async {
		let t = uptimeNS()
		let r = await runProcess("/bin/sh", ["-c", "echo started; exec sleep 600"], timeout: 0.5)
		#expect(r.status == 124 && r.out.hasPrefix("started\n") && r.out.hasSuffix("timed out after 0 s"))
		#expect(elapsedMS(t, uptimeNS()) < 5_000)
		let stubborn = await runProcess("/bin/sh", ["-c", "trap '' TERM; while :; do sleep 1; done"], timeout: 0.5)
		#expect(stubborn.status == 124)
		let quick = await runProcess("/bin/sh", ["-c", "exit 0"], timeout: 5)
		#expect(quick.status == 0 && quick.out.isEmpty)
	}

	/// A DHCP guest is found by its MAC: a stale binding moved the build VM to .3.
	@Test func dhcpAddressIsTheNewestBindingOfTheMAC() {
		let leases = """
			{
				name=CryosVilMachine
				ip_address=10.77.9.3
				hw_address=1,12:ab:cd:10:20:34
				lease=0x6af1f000
			}
			{
				ip_address=10.77.9.2
				hw_address=1,12:ab:cd:10:20:35
				lease=0x6af1e000
			}
			{
				ip_address=10.77.1.2
				hw_address=1,12:ab:cd:10:20:34
				lease=0x6af1ffff
			}
			{
				ip_address=10.77.9.4
				hw_address=1,12:ab:cd:10:20:34
				lease=0x6af10000
			}
			"""
		#expect(DHCPLeases.address(of: "12:ab:cd:10:20:34", subnet: 9, in: leases) == "10.77.9.3")
		#expect(DHCPLeases.address(of: "12:ab:cd:10:20:35", subnet: 9, in: leases) == "10.77.9.2")
		#expect(DHCPLeases.address(of: "00:00:00:00:00:01", subnet: 9, in: leases) == nil)
		#expect(DHCPLeases.octets("12:ab:cd:10:3:33") == DHCPLeases.octets("12:ab:cd:10:03:33"))
	}

	@Test func auxLockedMatchesOnlyTheEAGAINLockError() {
		let eagain = NSError(domain: NSPOSIXErrorDomain, code: Int(EAGAIN))
		#expect(ImageBuild.auxLocked(NSError(domain: VZErrorDomain, code: 2, userInfo: [NSUnderlyingErrorKey: eagain])))
		#expect(!ImageBuild.auxLocked(NSError(domain: VZErrorDomain, code: 2)))
		#expect(!ImageBuild.auxLocked(NSError(domain: VZErrorDomain, code: 6, userInfo: [NSUnderlyingErrorKey: eagain])))
	}

	@Test func rekeyCommandNamesTheHost() {
		let c = Guest.rekeyCommand(hostName: "cryo-x")
		#expect(c.contains("scutil --set HostName cryo-x"))
		// Every key type sshd-keygen-wrapper would otherwise make on the next login.
		#expect(c.contains("ssh-keygen -A"))
	}

	@Test func rekeyedHostKeyDropsCommentAndNoise() {
		let out = "Warning: something\nssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIKey root@cryo-x.local\n"
		#expect(Guest.rekeyedHostKey(from: out) == "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIKey")
		#expect(Guest.rekeyedHostKey(from: "sudo: a password is required\n") == nil)
	}
}

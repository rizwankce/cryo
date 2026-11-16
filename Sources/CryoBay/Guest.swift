import Darwin
import Foundation

/// Time in milliseconds between two `Clock.now()` readings, for the timings the bay prints.
func elapsedMS(_ a: UInt64, _ b: UInt64) -> Double { Double(b - a) / 1_000_000 }
func uptimeNS() -> UInt64 { clock_gettime_nsec_np(CLOCK_UPTIME_RAW) }

/// Polls `check` until it returns true or `timeout` seconds pass.
@MainActor
func waitFor(_ what: String, timeout: Double, every interval: Double, _ check: @MainActor () async -> Bool) async throws {
	let deadline = Date().addingTimeInterval(timeout)
	while Date() < deadline {
		if await check() { return }
		try await Task.sleep(for: .seconds(interval))
	}
	throw BayError("timed out after \(Int(timeout))s waiting for \(what)")
}

/// Runs a process to completion; stdout and stderr come back together. The pipe is drained while
/// the child runs (a child writing more than the ~64 KB pipe buffer would otherwise block forever),
/// and the call returns once both EOF and exit are seen. With a `timeout`, a child still running then
/// gets SIGTERM (SIGKILL 2 s later) and the call returns status 124 with "timed out after N s".
@discardableResult
func runProcess(
	_ exe: String, _ arguments: [String], stdin: Data? = nil, env extra: [String: String] = [:], timeout: Double? = nil
) async -> (status: Int32, out: String) {
	await withCheckedContinuation { cont in
		let p = Process()
		p.executableURL = URL(filePath: exe)
		p.arguments = arguments
		if !extra.isEmpty { p.environment = ProcessInfo.processInfo.environment.merging(extra) { $1 } }
		let out = Pipe()
		let input = Pipe()
		p.standardOutput = out
		p.standardError = out
		p.standardInput = stdin == nil ? FileHandle.nullDevice : input
		let exited = DispatchSemaphore(value: 0)
		p.terminationHandler = { _ in exited.signal() }
		do { try p.run() } catch {
			cont.resume(returning: (-1, "\(error)"))
			return
		}
		let timedOut = TimeoutFlag()
		if let timeout {
			DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
				guard p.isRunning else { return }
				timedOut.set()
				p.terminate()
				let pid = p.processIdentifier
				DispatchQueue.global().asyncAfter(deadline: .now() + 2) { if p.isRunning { kill(pid, SIGKILL) } }
			}
		}
		DispatchQueue.global().async {
			let data = out.fileHandleForReading.readDataToEndOfFile()
			exited.wait()
			let text = String(decoding: data, as: UTF8.self)
			if timedOut.isSet, let timeout {
				cont.resume(returning: (124, text + "timed out after \(Int(timeout)) s"))
			} else {
				cont.resume(returning: (p.terminationStatus, text))
			}
		}
		if let stdin {
			input.fileHandleForWriting.write(stdin)
			try? input.fileHandleForWriting.close()
		}
	}
}

/// Runs a process on this terminal (inherited stdin/stdout/stderr, same process group) and returns
/// its exit status. For `sudo`: under `runProcess` (stdin /dev/null, output piped, not in the
/// terminal's foreground group) its password prompt echoed the typing and never returned.
func runForeground(_ exe: String, _ arguments: [String]) async -> Int32 {
	await Task.detached {
		var pid: pid_t = 0
		let argv = ([exe] + arguments).map { strdup($0) } + [nil]
		defer { for p in argv { free(p) } }
		guard posix_spawn(&pid, exe, nil, nil, argv, environ) == 0 else { return -1 }
		var status: Int32 = 0
		while waitpid(pid, &status, 0) == -1 && errno == EINTR {}
		return (status & 0x7f) == 0 ? (status >> 8) & 0xff : 128 + (status & 0x7f)
	}.value
}

/// Set once by `runProcess`'s timer when it stops a child that ran too long.
private final class TimeoutFlag: @unchecked Sendable {
	private let lock = NSLock()
	private var value = false
	func set() { lock.withLock { value = true } }
	var isSet: Bool { lock.withLock { value } }
}

/// The bay's door into a running capsule: SSH as `cryo` with the image's key (docs/spec/capsule.md
/// "Guest contract"). Leases get their own keys; this one is for setup, refill and warm-up logins.
public struct Guest: Sendable {
	public let ip: String
	public let key: URL

	public init(ip: String, key: URL) {
		self.ip = ip
		self.key = key
	}

	public static let user = "cryo"

	/// Options that keep a login near 120 ms: `-F /dev/null` skips the user's ssh_config (agents,
	/// Includes, ~165 ms per connection), no agent, no GSSAPI, no known_hosts.
	func sshArguments() -> [String] {
		[
			"-F", "/dev/null",
			"-o", "StrictHostKeyChecking=no", "-o", "UserKnownHostsFile=/dev/null",
			"-o", "LogLevel=ERROR", "-o", "ConnectTimeout=2",
			// A guest that stops answering mid-session ends the login within ~15 s.
			"-o", "ServerAliveInterval=5", "-o", "ServerAliveCountMax=3",
			"-o", "GSSAPIAuthentication=no", "-o", "IdentityAgent=none",
			"-i", key.path, "-o", "IdentitiesOnly=yes", "-o", "BatchMode=yes",
			"\(Guest.user)@\(ip)",
		]
	}

	/// Short commands get `timeout` seconds, so a hung login can't stall a refill or a `waitFor` loop
	/// forever. Long ones (Xcode setup, warm-up builds) pass nil and rely on the keepalive.
	@discardableResult
	public func ssh(_ command: String, stdin: Data? = nil, timeout: Double? = 30) async -> (status: Int32, out: String) {
		await runProcess("/usr/bin/ssh", sshArguments() + [command], stdin: stdin, timeout: timeout)
	}

	/// Non-blocking TCP connect with a short timeout: finer-grained than spawning ssh.
	public static func portOpen(_ ip: String, _ port: UInt16 = 22, timeoutMs: Int32 = 200) -> Bool {
		let fd = socket(AF_INET, SOCK_STREAM, 0)
		guard fd >= 0 else { return false }
		defer { close(fd) }
		_ = fcntl(fd, F_SETFL, O_NONBLOCK)
		var addr = sockaddr_in()
		addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
		addr.sin_family = sa_family_t(AF_INET)
		addr.sin_port = port.bigEndian
		guard inet_pton(AF_INET, ip, &addr.sin_addr) == 1 else { return false }
		let r = withUnsafePointer(to: &addr) {
			$0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
				connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
			}
		}
		if r == 0 { return true }
		guard errno == EINPROGRESS else { return false }
		var pfd = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
		guard poll(&pfd, 1, timeoutMs) == 1 else { return false }
		var err: Int32 = 0
		var len = socklen_t(MemoryLayout<Int32>.size)
		getsockopt(fd, SOL_SOCKET, SO_ERROR, &err, &len)
		return err == 0
	}

	/// Port 22 probe off the main actor, so a 200 ms connect timeout never stalls the VM's run loop.
	public func probe() async -> Bool {
		let ip = ip
		return await Task.detached { Guest.portOpen(ip) }.value
	}

	/// Guest command that sets its clock to the host's current UTC time (whole seconds). The guest
	/// clock is still at freeze time after a restore, and the readiness login is the cheapest place to fix it.
	public static func clockCommand(now: Date = Date()) -> String {
		let f = DateFormatter()
		f.locale = Locale(identifier: "en_US_POSIX")
		f.timeZone = TimeZone(identifier: "UTC")
		f.dateFormat = "MMddHHmmyyyy.ss"
		return "sudo -n date -u \(f.string(from: now)) >/dev/null"
	}

	/// The guest's Ed25519 host key as seen from the host ("" if unreachable).
	public func hostKey() async -> String {
		let r = await runProcess("/usr/bin/ssh-keyscan", ["-T", "2", "-t", "ed25519", ip])
		return r.out.split(separator: "\n").first { !$0.hasPrefix("#") }.map { String($0.split(separator: " ").last ?? "") } ?? ""
	}

	/// Refill rekey: new host keys and host name, so no two leases share an identity. Prints
	/// the new Ed25519 public key, which the lease pins (read it with `rekeyedHostKey`). All three
	/// key types are made here: with only Ed25519, launchd's sshd-keygen-wrapper made RSA and ECDSA
	/// on the next login, which then missed the 2 s banner timeout.
	public static func rekeyCommand(hostName: String) -> String {
		"sudo -n sh -c 'rm -f /etc/ssh/ssh_host_*_key* && ssh-keygen -A >/dev/null && scutil --set HostName \(hostName) && cat /etc/ssh/ssh_host_ed25519_key.pub'"
	}

	/// `ssh-ed25519 <base64>` from the rekey output (the key file's comment dropped), nil if absent.
	public static func rekeyedHostKey(from output: String) -> String? {
		for line in output.split(separator: "\n").reversed() {
			let f = line.split(separator: " ")
			if f.count >= 2, f[0] == "ssh-ed25519" { return "ssh-ed25519 \(f[1])" }
		}
		return nil
	}
}

/// bootpd's lease file (world-readable). vmnet's DHCP reservation for a guest's .2 didn't reliably
/// reach bootpd, so a VM that boots on DHCP (image build, a freeze's first boot) is found by
/// its MAC here instead of assumed at .2.
public enum DHCPLeases {
	public static let path = "/var/db/dhcpd_leases"

	public struct Binding: Equatable, Sendable {
		public var ip: String
		public var mac: [UInt8]
		public var lease: UInt64
	}

	/// bootpd drops leading zeros in MACs (`9:c3`), so octets are compared as numbers.
	public static func octets(_ mac: String) -> [UInt8] { mac.split(separator: ":").compactMap { UInt8($0, radix: 16) } }

	public static func parse(_ text: String) -> [Binding] {
		text.split(separator: "}").compactMap { block in
			var ip: String?
			var mac: [UInt8] = []
			var lease: UInt64 = 0
			for line in block.split(separator: "\n") {
				let t = line.trimmingCharacters(in: .whitespaces)
				if t.hasPrefix("ip_address=") { ip = String(t.dropFirst("ip_address=".count)) }
				if t.hasPrefix("hw_address=1,") { mac = octets(String(t.dropFirst("hw_address=1,".count))) }
				if t.hasPrefix("lease=0x") { lease = UInt64(t.dropFirst("lease=0x".count), radix: 16) ?? 0 }
			}
			return ip.map { Binding(ip: $0, mac: mac, lease: lease) }
		}
	}

	/// The newest address bootpd gave `mac` on 10.77.`subnet`.0/24, if any.
	public static func address(of mac: String, subnet: Int, in text: String) -> String? {
		let m = octets(mac)
		return parse(text).filter { $0.mac == m && $0.ip.hasPrefix("10.77.\(subnet).") }.max { $0.lease < $1.lease }?.ip
	}

	/// The guest's address now: its DHCP binding, else the capsule's .2.
	public static func guestIP(mac: String, subnet: Int) -> String {
		address(of: mac, subnet: subnet, in: (try? String(contentsOfFile: path, encoding: .utf8)) ?? "")
			?? CapsuleNetwork(subnet: subnet).guestIP
	}
}

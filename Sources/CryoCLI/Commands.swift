import CryoAPI
import CryoClient
import CryoHTTP

#if os(macOS)
	import CryoBay
#endif

#if canImport(FoundationEssentials)
	import FoundationEssentials
#else
	import Foundation
#endif

private let hintLine = "hint: ~/.ssh/config does not include ~/.cryo/ssh_config; run `cryo setup`"

private func requireID(_ p: ParsedArgs) throws -> String {
	guard p.positionals.count >= 1 else { throw UsageError(message: "missing <id>") }
	return p.positionals[0]
}

private func noExtra(_ p: ParsedArgs, max: Int) throws {
	if p.positionals.count > max { throw UsageError(message: "unexpected argument '\(p.positionals[max])'") }
}

private func printJSON<T: Encodable>(_ ctx: CLIContext, _ value: T) throws {
	let e = CryoJSON.encoder()
	e.outputFormatting.insert(.prettyPrinted)
	ctx.say(String(decoding: try e.encode(value), as: UTF8.self))
}

// MARK: lease

func leaseCommand(_ ctx: CLIContext, _ p: ParsedArgs) throws -> Int32 {
	try noExtra(p, max: 0)
	// Without --wait or --idle the request leaves them out, so the bay's own defaults apply.
	var wait: Int?
	if let w = p.values["wait"] {
		guard let n = Int(w), n >= 0 else { throw UsageError(message: "--wait must be a number of seconds, got '\(w)'") }
		wait = n
	}
	var idle: Int?
	if let i = p.values["idle"] {
		guard let s = parseIdle(i) else {
			throw UsageError(message: "--idle must look like 90s, 60m, 2h or bare minutes, got '\(i)'")
		}
		idle = s
	}
	let folder = p.values["folder"].map { absolutePath($0, cwd: ctx.cwd) }
	let req = LeaseRequest(folder: folder, cache: p.values["cache"], waitS: wait, name: p.values["name"], idleS: idle)
	let lease: Lease
	do {
		lease = try ctx.client.createLease(req)
	} catch CryoClientError.api(let e, _) where e.code == APIError.noCapacity {
		ctx.warn("cryo lease: \(e.message)")  // the bay says why: busy, or frozen until doctor passes
		return 1
	}
	let local = LocalState(home: ctx.home)
	do {
		try local.saveLease(lease, bay: ctx.target)
	} catch {
		// Without its key nobody can use the lease; give the capsule back instead of holding it idle.
		try? ctx.client.release(lease.id)
		local.removeLease(lease.id)
		throw error
	}
	if p.flag("json") {
		try printJSON(ctx, lease)
	} else {
		ctx.say("\(lease.id) ready: ssh \(lease.ssh.host)")
	}
	if !local.userConfigIncludesCryo { ctx.warn(hintLine) }
	return 0
}

// MARK: release

func releaseCommand(_ ctx: CLIContext, _ p: ParsedArgs) throws -> Int32 {
	let id = try requireID(p)
	try noExtra(p, max: 1)
	let local = LocalState(home: ctx.home)
	do {
		try ctx.client.release(id, saveCache: p.flag("save-cache"))
	} catch CryoClientError.api(let e, let status) {
		// The bay does not know it (anymore): clean up here anyway, still report.
		if e.code == APIError.notFound { local.removeLease(id) }
		throw CryoClientError.api(e, status: status)
	}
	local.removeLease(id)
	ctx.say("\(id) released")
	return 0
}

// MARK: ls

private func relative(_ date: Date, now: Date) -> String {
	let s = Int(date.timeIntervalSince(now).rounded())
	return s < 0 ? "overdue" : "in " + span(s)
}

/// `45s`, `12m`, `5h`, `3d`.
private func span(_ s: Int) -> String {
	if s < 90 { return "\(s)s" }
	if s < 90 * 60 { return "\((s + 30) / 60)m" }
	if s < 48 * 3600 { return "\((s + 1800) / 3600)h" }
	return "\(s / 86400)d"
}

/// `1234 ms` below 10 s, else `12.3 s`.
private func millis(_ ms: Int) -> String {
	ms < 10_000 ? "\(ms) ms" : "\(ms / 1000).\(ms % 1000 / 100) s"
}

func healthLines(_ h: Status.Health) -> [String] {
	let disk = h.diskFreeBytes.map { "disk \($0 / 1_000_000_000) GB free" } ?? "disk free unknown"
	let lastLease = h.lastLeaseMS.map { " (last \(millis($0)))" } ?? ""
	let lastRefill = h.lastRefillMS.map { " (last \(millis($0)))" } ?? ""
	return [
		"health: bay up \(span(h.uptimeS)), host up \(span(h.hostUptimeS)), \(disk), thermal \(h.thermal)",
		"leases: \(h.leasesServed) served, \(h.leasesFailed) failed, \(h.leasesExpired) expired\(lastLease); "
			+ "refills: \(h.refills) ok, \(h.refillsFailed) failed\(lastRefill)",
	]
}

func table(_ rows: [[String]]) -> String {
	guard let first = rows.first else { return "" }
	var widths = [Int](repeating: 0, count: first.count)
	for r in rows { for (i, c) in r.enumerated() { widths[i] = max(widths[i], c.count) } }
	return rows.map { r in
		var line = ""
		for (i, c) in r.enumerated() {
			line += i == r.count - 1 ? c : c + String(repeating: " ", count: widths[i] - c.count + 2)
		}
		return line
	}.joined(separator: "\n") + "\n"
}

func lsCommand(_ ctx: CLIContext, _ p: ParsedArgs) throws -> Int32 {
	try noExtra(p, max: 0)
	let leases = try ctx.client.listLeases()
	// Only this bay's leases: local state holds the leases of every bay CRYO_URL has pointed at.
	LocalState(home: ctx.home).forgetLeases(except: Set(leases.map(\.id)), on: ctx.target)
	if p.flag("json") {
		try printJSON(ctx, leases)
		return 0
	}
	if leases.isEmpty {
		ctx.say("no leases")
		return 0
	}
	let now = Date()
	var rows = [["ID", "NAME", "CAPSULE", "STATE", "CACHE", "RENEW BY", "EXPIRES"]]
	for l in leases {
		rows.append([
			l.id, l.name ?? "-", String(l.capsule), l.state, l.cache ?? "-",
			relative(l.renewBy, now: now), relative(l.expiresAt, now: now),
		])
	}
	ctx.out(table(rows))
	return 0
}

// MARK: status

func statusCommand(_ ctx: CLIContext, _ p: ParsedArgs) throws -> Int32 {
	try noExtra(p, max: 0)
	let s: Status
	do {
		s = try ctx.client.status()
	} catch let error as CryoClientError {
		// A bay restarting every minute on taken subnets is down most of the time: say why.
		guard case .transport = error, let alert = restartNote(ctx.target) else { throw error }
		if p.flag("json") {
			try printJSON(ctx, RestartingStatus(bay: .init(state: "restarting", alert: alert)))
			return 1
		}
		ctx.say("bay: restarting every minute (no bay is up right now)")
		ctx.say("ALERT: \(alert)")
		return 1
	}
	if p.flag("json") {
		try printJSON(ctx, s)
		return 0
	}
	ctx.say("bay: version \(s.bay.version), image \(s.bay.image), doctor \(s.bay.doctorOK ? "ok" : "failing (run `cryo doctor`)")")
	if let alert = s.bay.alert { ctx.say("ALERT: \(alert)") }
	if let blocked = s.bay.blockedBy { ctx.say("capsules frozen until these pass: \(blocked.joined(separator: "; "))") }
	for line in s.health.map(healthLines) ?? [] { ctx.say(line) }
	var rows: [[String]] = []
	for c in s.capsules {
		rows.append(["capsule \(c.n)", c.state, c.lease ?? "-"])
	}
	if !rows.isEmpty { ctx.out(table(rows)) }
	ctx.say("queue: \(s.queue)")
	return 0
}

/// `cryo status --json` while no bay answers but one is restarting: `{"bay":{"state":"restarting","alert":…}}`.
struct RestartingStatus: Codable {
	struct Bay: Codable {
		var state: String
		var alert: String
	}
	var bay: Bay
}

/// The alert a restarting bay left next to its unix socket, if it's recent (`RestartNote`).
func restartNote(_ target: CryoTarget, now: Date = Date()) -> String? {
	guard case .unix(let socket) = target.endpoint else { return nil }
	let path = String(socket[..<(socket.lastIndex(of: "/") ?? socket.startIndex)]) + "/" + RestartNote.fileName
	guard let text = readTextFile(path) else { return nil }
	return RestartNote.parse(text, now: now.timeIntervalSince1970)
}

// MARK: ssh

func sshCommand(_ ctx: CLIContext, _ p: ParsedArgs) throws -> Int32 {
	let id = try requireID(p)
	let extra = Array(p.positionals.dropFirst())
	let local = LocalState(home: ctx.home)

	// A command always runs over ssh: agents' shells have no terminal on stdin either. Only
	// `cryo ssh <id>` alone with a non-terminal stdin is ssh's ProxyCommand.
	if extra.isEmpty && !ctx.stdinIsTTY {
		// ProxyCommand: stdout is the SSH stream, so nothing but errors goes to stderr.
		let stream = try ctx.client.connect(id)
		defer { stream.close() }
		try pipe(stream, stdinFD: ctx.stdinFD, stdoutFD: ctx.stdoutFD)
		return 0
	}

	var host = local.host(for: id)
	if host == nil {
		let lease = try ctx.client.lease(id)
		try local.saveLease(lease, bay: ctx.target)
		host = local.host(for: id) ?? lease.ssh.host
	}
	return ctx.exec(["ssh", "-F", local.sshConfig, host!] + extra)
}

// MARK: logs

let defaultLogLines = 50

/// `-f` and `-n N` (or `-nN`) as the parser's `--follow` and `--lines N`.
func logsArguments(_ args: [String]) -> [String] {
	args.map { a in
		if a == "-f" { return "--follow" }
		if a == "-n" { return "--lines" }
		if a.hasPrefix("-n"), a.count > 2, a.dropFirst(2).allSatisfy(\.isNumber) { return "--lines=" + a.dropFirst(2) }
		return a
	}
}

/// The log the installed bay writes (`BayPaths.log`): `$CRYO_HOME/bay.log`, else `~/.cryo/bay.log`.
func bayLogPath(_ ctx: CLIContext) -> String {
	let root = ctx.environment["CRYO_HOME"].flatMap { $0.isEmpty ? nil : $0 } ?? LocalState(home: ctx.home).cryoDir
	return root + "/bay.log"
}

private let logsElsewhere = """
	The installed bay (`cryo bay install`) writes its output there; a bay started with
	`cryo bay start` in a terminal prints to that terminal. Its unified log:
	  log show --last 1h --predicate 'subsystem == "dev.rizwan.cryo.bay"'
	"""

/// Prints the last lines of the bay's log; with `--follow`, then what the bay appends.
func logsCommand(_ ctx: CLIContext, _ p: ParsedArgs) throws -> Int32 {
	try noExtra(p, max: 0)
	var count = defaultLogLines
	if let n = p.values["lines"] {
		guard let v = Int(n), v >= 0 else { throw UsageError(message: "-n must be a number of lines, got '\(n)'") }
		count = v
	}
	#if !os(macOS)
		_ = count
		ctx.warn("cryo logs: macOS bay only; on the bay's Mac its log is ~/.cryo/bay.log (run `cryo logs` there)")
		return 1
	#else
		let path = bayLogPath(ctx)
		let fd = open(path, O_RDONLY | O_CLOEXEC)
		guard fd >= 0 else {
			ctx.warn("cryo logs: no bay log at \(path)\n" + logsElsewhere)
			return 1
		}
		defer { close(fd) }
		var st = stat()
		guard fstat(fd, &st) == 0 else { throw FileError(description: "cannot read \(path): \(String(cString: strerror(errno)))") }
		let size = Int(st.st_size)
		ctx.out(String(decoding: lastLines(fd, size: size, count: count), as: UTF8.self))
		if p.flag("follow") { followLog(path, fd: fd, from: size, out: ctx.out) }
		return 0
	#endif
}

/// The last `count` lines of the open file, read backwards from `size` in chunks.
func lastLines(_ fd: Int32, size: Int, count: Int) -> [UInt8] {
	if count <= 0 || size <= 0 { return [] }
	var data: [UInt8] = []
	var start = size
	var newlines = 0
	// A newline ending the file ends the last line; it does not start another.
	var endsWithNewline: Bool?
	while start > 0 && newlines <= count {
		let chunk = min(64 * 1024, start)
		var buf = [UInt8](repeating: 0, count: chunk)
		let got = buf.withUnsafeMutableBytes { pread(fd, $0.baseAddress, chunk, off_t(start - chunk)) }
		if got != chunk { break }  // shrank under us: print what we have
		start -= chunk
		if endsWithNewline == nil { endsWithNewline = buf.last == 10 }
		newlines += buf.reduce(0) { $0 + ($1 == 10 ? 1 : 0) }
		data = buf + data
	}
	let skip = endsWithNewline == true ? 1 : 0
	var seen = 0
	var i = data.count - skip
	while i > 0 {
		i -= 1
		if data[i] == 10 {
			seen += 1
			if seen == count { return Array(data[(i + 1)...]) }
		}
	}
	return data
}

/// Prints what is appended to the log, whole lines at a time, until `keepGoing` says stop (Ctrl-C
/// for the command). Starts over when the log is emptied (the bay trims it at start) or replaced.
func followLog(
	_ path: String, fd: Int32, from offset: Int, out: (String) -> Void,
	interval: UInt32 = 250_000, keepGoing: () -> Bool = { true }
) {
	var fd = fd
	var ownsFD = false
	var offset = offset
	var partial: [UInt8] = []
	var buf = [UInt8](repeating: 0, count: 64 * 1024)
	defer { if ownsFD { close(fd) } }
	while keepGoing() {
		var now = stat()
		var openStat = stat()
		if stat(path, &now) == 0, fstat(fd, &openStat) == 0, now.st_ino != openStat.st_ino || now.st_dev != openStat.st_dev {
			let next = open(path, O_RDONLY | O_CLOEXEC)
			if next >= 0 {
				if ownsFD { close(fd) }
				fd = next
				ownsFD = true
				offset = 0
				partial = []
			}
		}
		if fstat(fd, &openStat) == 0, Int(openStat.st_size) < offset {
			offset = 0
			partial = []
		}
		while true {
			let n = buf.withUnsafeMutableBytes { pread(fd, $0.baseAddress, $0.count, off_t(offset)) }
			if n <= 0 { break }
			offset += n
			partial += buf[0..<n]
			if let last = partial.lastIndex(of: 10) {
				out(String(decoding: partial[...last], as: UTF8.self))
				partial.removeSubrange(...last)
			}
		}
		usleep(interval)
	}
}

// MARK: setup

func setupCommand(_ ctx: CLIContext, _ p: ParsedArgs) throws -> Int32 {
	try noExtra(p, max: 0)
	let local = LocalState(home: ctx.home)
	let line = "Include ~/.cryo/ssh_config"

	try makeDirs(local.cryoDir, mode: 0o700)
	if !pathExists(local.sshConfig) { try writeAtomically(local.sshConfig, "", mode: 0o600) }
	try makeDirs(local.userSSHDir, mode: 0o700)
	if !pathExists(local.userSSHConfig) { try writeAtomically(local.userSSHConfig, "", mode: 0o600) }

	let current = readTextFile(local.userSSHConfig) ?? ""
	if local.includesCryo(current) {
		ctx.say("~/.ssh/config already includes ~/.cryo/ssh_config; nothing to do")
		return 0
	}
	ctx.say("cryo will add this line at the top of ~/.ssh/config (it must come before any Host block):\n\n  \(line)\n")
	if !p.flag("yes") {
		guard ctx.stdinIsTTY else {
			ctx.warn("cryo setup: not changing ~/.ssh/config without confirmation; rerun with `cryo setup --yes`")
			return 1
		}
		ctx.out("Add it? [y/N] ")
		let answer = ctx.readLine()?.trimmingSpaces().lowercased() ?? ""
		guard answer == "y" || answer == "yes" else {
			ctx.say("left ~/.ssh/config unchanged")
			return 0
		}
	}
	try writeAtomically(local.userSSHConfig, line + "\n\n" + current, mode: 0o600)
	ctx.say("added; `ssh cryo-<id>` now works for your leases")
	return 0
}

// MARK: doctor (macOS bay; compiled everywhere so Linux builds check it)

/// Prints the bay's checks (host, image, capsules). With no bay running on this Mac, prints the host
/// checks alone, so `cryo bay install` can run it first. `--fix` applies the safe host fixes, then
/// checks again (docs/spec/setup.md).
func doctorCommand(_ ctx: CLIContext, _ p: ParsedArgs) throws -> Int32 {
	var failed = try printDoctor(ctx)
	#if os(macOS)
		if failed && p.flag("fix") {
			guard case .unix = ctx.target.endpoint else {
				ctx.warn("cryo doctor: --fix changes this Mac, not a remote bay; unset CRYO_URL")
				return 1
			}
			let fixable = HostDoctor.localChecks().filter { $0.fix != nil }
			if fixable.isEmpty {
				ctx.warn("cryo doctor: nothing here that --fix changes; follow the hints above")
				return 1
			}
			for c in fixable {
				ctx.say("fixing: \(c.result.check)")
				_ = HostDoctor.apply(c.fix!) { ctx.say($0) }
			}
			ctx.say("")
			failed = try printDoctor(ctx)
		}
	#endif
	return failed ? 1 : 0
}

/// Prints one line per check; returns whether any failed.
private func printDoctor(_ ctx: CLIContext) throws -> Bool {
	let checks: [DoctorCheck]
	do {
		checks = try ctx.client.doctor()
	} catch let error as CryoClientError {
		#if os(macOS)
			guard case .transport(let target, _) = error, target.hasPrefix("unix://") else { throw error }
			ctx.say("bay not running (\(target)); host checks only")
			checks = HostDoctor.localChecks().map(\.result)
		#else
			throw error
		#endif
	}
	var failed = false
	for c in checks {
		if c.ok {
			ctx.say("ok    \(c.check)")
		} else {
			failed = true
			ctx.say("FAIL  \(c.check)" + (c.fix.map { " (fix: \($0))" } ?? ""))
		}
	}
	return failed
}

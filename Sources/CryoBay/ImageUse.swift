import Foundation

/// `cryo image use` and `cryo image rm` (docs/spec/image.md "Identity and use"). `use` runs with
/// the bay stopped: the bay holds both capsules' VMs and Apple allows 2 per Mac, so stopping the
/// bay is the drain and starting it again the undrain. The decisions are pure (`ImageRef`,
/// `ImageUsePlan`, `ImageRemoval`) so tests cover them without VMs.

/// Finds an image by full digest, tag or unique digest prefix.
enum ImageRef {
	static func resolve(_ ref: String, in images: [ImageInfo]) throws -> String {
		guard !ref.isEmpty else { throw BayError("no image given") }
		if images.contains(where: { $0.digest == ref }) { return ref }
		let tagged = images.filter { $0.tag == ref }
		if tagged.count == 1 { return tagged[0].digest }
		if tagged.count > 1 {
			throw BayError("tag \(ref) is on \(tagged.count) images (\(tagged.map(\.digest).sorted().joined(separator: ", "))); give a digest")
		}
		let prefixed = images.filter { $0.digest.hasPrefix(ref) }
		if prefixed.count == 1 { return prefixed[0].digest }
		if prefixed.count > 1 {
			throw BayError("\(ref) matches \(prefixed.count) images (\(prefixed.map(\.digest).sorted().joined(separator: ", "))); give more of the digest")
		}
		throw BayError("no image \(ref) (cryo image ls)")
	}

	/// Every image under `images/` with a readable `image.json`; the directory name is the digest.
	static func catalog(_ paths: BayPaths) -> [ImageInfo] {
		let names = ((try? FileManager.default.contentsOfDirectory(atPath: paths.images.path)) ?? []).filter { !$0.hasPrefix(".") }
		return names.sorted().compactMap { name in
			guard var info = try? BayJSON.read(ImageInfo.self, from: paths.image(name).info) else { return nil }
			info.digest = name
			return info
		}
	}
}

/// What `cryo image use` freezes: which capsules, on which subnets, with which warm-up.
struct ImageUsePlan: Equatable {
	struct Capsule: Equatable {
		var n: Int
		var subnet: Int
	}
	var capsules: [Capsule]
	var warmUp: [String]?

	/// `count` capsules: the existing ones first (the bay serves the lowest numbers), each keeping
	/// its subnet; missing ones get the lowest free number and subnet, never the build VM's default
	/// (kept free for the next `cryo image build`). Warm-up: `warmUp` when given (`[]` = none), else
	/// iOS for an Xcode image.
	static func make(existing: [Int: Int], count: Int, image: ImageInfo, warmUp: [String]? = nil) -> ImageUsePlan {
		var capsules = existing.keys.sorted().prefix(count).map { Capsule(n: $0, subnet: existing[$0]!) }
		var usedSubnets = Set(existing.values).union([ImageBuild.defaultSubnet])
		var n = 0
		while capsules.count < count {
			if existing[n] == nil {
				var s = 0
				while usedSubnets.contains(s) { s += 1 }
				usedSubnets.insert(s)
				capsules.append(Capsule(n: n, subnet: s))
			}
			n += 1
		}
		let w = warmUp.map { $0.isEmpty ? nil : $0 } ?? ((image.xcode != nil || image.tag.hasPrefix("xcode-")) ? ["ios"] : nil)
		return ImageUsePlan(capsules: capsules.sorted { $0.n < $1.n }, warmUp: w)
	}

	/// Where this process freezes a capsule before the swap. Start-up cleanup deletes leftovers
	/// (`.tmp-`) once their process is gone.
	static func staging(_ n: Int, pid: Int32 = getpid()) -> String { Leftovers.staging("use", n, pid: pid) }
}

/// `cryo image rm` refuses the configured image and any image a capsule is frozen on.
enum ImageRemoval {
	static func check(_ digest: String, configured: String?, capsuleImages: [Int: String]) throws {
		if digest == configured { throw BayError("image \(digest) is in use (config.toml); switch first with cryo image use <other>") }
		let users = capsuleImages.filter { $0.value == digest }.keys.sorted()
		if !users.isEmpty {
			throw BayError("capsule \(users.map(String.init).joined(separator: ", ")) is frozen on image \(digest); cryo image use <other> first")
		}
	}
}

enum ImageUse {
	static func capsuleManifests(_ paths: BayPaths) -> [Int: CapsuleManifest] {
		var r: [Int: CapsuleManifest] = [:]
		for n in capsuleNumbers(paths) {
			if let m = try? BayJSON.read(CapsuleManifest.self, from: paths.capsule(n).manifest) { r[n] = m }
		}
		return r
	}

	// MARK: use

	@MainActor
	static func use(_ args: [String], paths: BayPaths, out: BayCommand.Writer) async throws -> Int32 {
		let usage =
			"usage: cryo image use <digest|prefix|tag> [--warm-up [ios,macos] | --no-warm-up] [--settle \(Freeze.settleS)] [--verify-tries \(Freeze.verifyTries)]"
		let o = Freeze.Options(args: args)
		guard let ref = args.first, !ref.hasPrefix("-") else { throw BayError(usage) }
		let digest = try ImageRef.resolve(ref, in: ImageRef.catalog(paths))
		let (_, image) = try Freeze.resolveImage(Freeze.Options(args: ["--image", digest]), paths: paths)
		let info = try BayJSON.read(ImageInfo.self, from: image.info)
		try Cleanup.refuseWhileBayRuns(paths)
		let warmUp: [String]?
		if o.flag("--no-warm-up") {
			warmUp = []
		} else if o.flag("--warm-up") {
			warmUp = try WarmUp.platforms(o.value("--warm-up").flatMap { $0.hasPrefix("--") ? nil : $0 })
		} else {
			warmUp = nil
		}
		let settle = Double(try o.int("--settle") ?? Freeze.settleS)
		let tries = try o.int("--verify-tries") ?? Freeze.verifyTries
		var config = try BayConfig.load(paths.config)
		try paths.prepare()
		// A `use` or refreeze that crashed half way: put swapped-out capsules back, drop staging.
		Cleanup.repairRefreezes(paths)

		let existing = capsuleManifests(paths).mapValues(\.network.subnet)
		let plan = ImageUsePlan.make(existing: existing, count: config.capsules, image: info, warmUp: warmUp)
		out(
			"using image \(digest) (\(info.tag)): freezing capsule \(plan.capsules.map { "\($0.n) (subnet \($0.subnet))" }.joined(separator: ", "))"
				+ (plan.warmUp.map { ", warm-up \($0.joined(separator: ","))" } ?? "") + "\n")

		// Freeze every capsule into staging first, so a failure leaves the old capsules and config as they were.
		let fm = FileManager.default
		let staged = plan.capsules.map { Freeze.staging("use", $0.n, paths: paths) }
		do {
			_ = try await CapsuleVM.session {
				for (planned, capsule) in zip(plan.capsules, staged) {
					_ = try await Freeze.freezeVerified(
						paths: paths, image: image, digest: digest, info: info, capsule: capsule, subnet: planned.subnet, settle: settle,
						warmUp: plan.warmUp, tries: tries, out: out)
				}
				return 0
			}
			// Swap them all in (a failure puts the old ones back; start-up repairs an interrupted swap),
			// then point the config at the image.
			try Freeze.swapIn(zip(plan.capsules, staged).map { ($1.dir, paths.capsule($0.n)) }, paths: paths)
		} catch {
			for c in staged { try? fm.removeItem(at: c.dir) }
			throw error
		}
		let previous = config.image
		config.image = digest
		try config.save(paths.config)
		out(
			"image \(digest) (\(info.tag)) in use\(previous.map { $0 == digest ? "" : "; was \($0) (cryo image rm \(String($0.prefix(12))) frees it)" } ?? "")\n"
		)
		out("start the bay again: launchctl bootstrap gui/\(getuid()) ~/Library/LaunchAgents/\(BayInstall.agentLabel).plist (or cryo bay start)\n")
		return 0
	}

	// MARK: rm

	static func rm(_ args: [String], paths: BayPaths, out: BayCommand.Writer) throws -> Int32 {
		guard args.count == 1, let ref = args.first, !ref.hasPrefix("-") else { throw BayError("usage: cryo image rm <digest|prefix|tag>") }
		let digest = try ImageRef.resolve(ref, in: ImageRef.catalog(paths))
		let config = try BayConfig.load(paths.config)
		try ImageRemoval.check(digest, configured: config.image, capsuleImages: capsuleManifests(paths).mapValues(\.image))
		try FileManager.default.removeItem(at: paths.image(digest).dir)
		out("removed image \(digest)\n")
		return 0
	}
}

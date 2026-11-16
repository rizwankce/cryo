import Foundation

/// Capsule numbers present under `capsules/` (temporary `.tmp-` directories are skipped).
func capsuleNumbers(_ paths: BayPaths) -> [Int] {
	((try? FileManager.default.contentsOfDirectory(atPath: paths.capsules.path)) ?? []).compactMap { Int($0) }.sorted()
}

/// Reasons this capsule's saved state shouldn't be restored here; empty = fine. Pure file work, so
/// `doctor` and `cryo bay capsules` can call it without Virtualization. The comparison is the
/// thaw's own (`CapsuleManifest.mismatches`), so "saved state matches" means a refill restores;
/// on top of it, the files a restore needs must exist. `digest` is the configured image; nil
/// reads it from config.toml (and with none configured, the manifest's image counts).
public func manifestProblems(paths: BayPaths, capsule n: Int, digest: String? = nil) -> [String] {
	let c = paths.capsule(n)
	guard let m = try? BayJSON.read(CapsuleManifest.self, from: c.manifest) else { return ["manifest.json missing or unreadable"] }
	var problems: [String] = []
	let image = paths.image(m.image)
	if !FileManager.default.fileExists(atPath: image.dir.path) { problems.append("image \(m.image) missing") }
	if !FileManager.default.fileExists(atPath: c.state.path) { problems.append("state.vzstate missing") }
	if !FileManager.default.fileExists(atPath: c.aux.path) { problems.append("aux.img missing") }
	let configured = digest ?? (try? BayConfig.load(paths.config))?.image ?? m.image
	// The thaw stamps the configured image's files (CapsuleVM.thaw), so compare against those too.
	return problems + m.mismatches(image: paths.image(configured), capsule: c, digest: configured)
}

enum BayInventory {
	static func size(_ u: URL) -> String {
		let b = (try? FileManager.default.attributesOfItem(atPath: u.path)[.size] as? Int) ?? 0
		return String(format: "%.1f GB", Double(b) / 1e9)
	}

	static func pad(_ s: String, _ n: Int) -> String { s.padding(toLength: max(n, s.count + 2), withPad: " ", startingAt: 0) }

	static func images(paths: BayPaths, out: BayCommand.Writer) -> Int32 {
		let names = ((try? FileManager.default.contentsOfDirectory(atPath: paths.images.path)) ?? []).filter { !$0.hasPrefix(".") }.sorted()
		if names.isEmpty {
			out("no images (cryo image build)\n")
			return 0
		}
		let current = (try? BayConfig.load(paths.config))?.image
		out(pad("DIGEST", 18) + pad("TAG", 16) + pad("BASE", 10) + "\n")
		for n in names {
			let img = paths.image(n)
			let info = try? BayJSON.read(ImageInfo.self, from: img.info)
			out(pad(n, 18) + pad(info?.tag ?? "?", 16) + pad(size(img.base), 10) + (n == current ? "(in use)" : "") + "\n")
		}
		return 0
	}

	static func capsules(paths: BayPaths, out: BayCommand.Writer) -> Int32 {
		let numbers = capsuleNumbers(paths)
		if numbers.isEmpty {
			out("no capsules (cryo image use <digest>)\n")
			return 0
		}
		out(pad("N", 4) + pad("IMAGE", 18) + pad("SUBNET", 14) + pad("FROZEN AT", 22) + "CHECK\n")
		let f = ISO8601DateFormatter()
		let configured = (try? BayConfig.load(paths.config))?.image
		for n in numbers {
			let m = try? BayJSON.read(CapsuleManifest.self, from: paths.capsule(n).manifest)
			let problems = manifestProblems(paths: paths, capsule: n, digest: configured)
			out(
				pad(String(n), 4) + pad(m?.image ?? "?", 18) + pad(m.map { "10.77.\($0.network.subnet).0/24" } ?? "?", 14)
					+ pad(m.map { f.string(from: $0.frozenAt) } ?? "?", 22) + (problems.isEmpty ? "ok" : problems.joined(separator: "; ")) + "\n")
		}
		return 0
	}
}

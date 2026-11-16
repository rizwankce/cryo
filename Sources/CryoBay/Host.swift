import Foundation

public enum Host {
	/// `model | chip | macOS build`, e.g. `Mac16,10 | Apple M4 | macOS 27.2 (27C52)`.
	/// Saved states are bound to the host; a different fingerprint means don't trust a restore.
	public static func fingerprint() -> String {
		let v = ProcessInfo.processInfo.operatingSystemVersion
		let build = sysctlString("kern.osversion")
		return "\(sysctlString("hw.model")) | \(sysctlString("machdep.cpu.brand_string")) | macOS \(v.majorVersion).\(v.minorVersion) (\(build))"
	}

	/// `size@mtime` of a file (mtime in whole seconds), or `missing`. Manifests store these for the
	/// files a saved state depends on; APFS clones keep both when made with `clonefile`.
	public static func stamp(_ url: URL) -> String {
		guard let a = try? FileManager.default.attributesOfItem(atPath: url.path),
			let size = a[.size] as? Int, let mtime = a[.modificationDate] as? Date
		else { return "missing" }
		return "\(size)@\(Int(mtime.timeIntervalSince1970))"
	}

	static func sysctlString(_ name: String) -> String {
		var size = 0
		guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return "?" }
		var buf = [CChar](repeating: 0, count: size)
		guard sysctlbyname(name, &buf, &size, nil, 0) == 0 else { return "?" }
		return String(decoding: buf.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
	}
}

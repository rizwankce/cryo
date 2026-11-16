import Foundation

/// Warm-up build at freeze time: building any SwiftUI package once fills the shared folders
/// at the DerivedData root (`SDKExplicitPrecompiledModules`, `ModuleCache.noindex`,
/// `CompilationCache.noindex`) that every later project reuses. An iOS project's first build in a
/// lease drops from ~48 s to 15-21 s. The project's own folder is deleted; only the shared caches
/// stay in the image. No Simulator is booted.
enum WarmUp {
	/// Platforms to warm, as `xcodebuild -destination` values.
	static let destinations: [String: String] = [
		"ios": "generic/platform=iOS Simulator",
		"macos": "generic/platform=macOS",
	]

	/// Runs in the guest; prints one `warm-up <platform>: <seconds> s rc=<n>` line per platform.
	static func script(platforms: [String]) -> String {
		var s = """
			set -u
			W=$(mktemp -d /tmp/cryo-warmup.XXXXXX)
			mkdir -p "$W/Sources/WarmUp"
			cat > "$W/Package.swift" <<'EOF'
			// swift-tools-version: 6.0
			import PackageDescription
			let package = Package(name: "WarmUp", platforms: [.iOS("27.0"), .macOS("27.0")],
				products: [.library(name: "WarmUp", targets: ["WarmUp"])], targets: [.target(name: "WarmUp")])
			EOF
			for i in 1 2 3 4 5; do cat > "$W/Sources/WarmUp/View$i.swift" <<EOF
			import SwiftUI
			import Observation
			import Foundation

			@Observable final class Model$i { var items: [String] = (0..<20).map { "Item \\(\\$0)" }; var selected: String? }

			public struct Screen$i: View {
				@State private var model = Model$i()
				@State private var query = ""
				public init() {}
				public var body: some View {
					NavigationStack {
						List(model.items.filter { query.isEmpty || \\$0.contains(query) }, id: \\.self) { item in
							HStack { Image(systemName: "star"); Text(item).font(.headline); Spacer(); Text(Date.now, style: .time) }
								.onTapGesture { model.selected = item }
						}
						.searchable(text: \\$query)
						.navigationTitle("Screen $i")
						.toolbar { Button("Add") { model.items.append(UUID().uuidString) } }
					}
				}
			}
			EOF
			done
			cd "$W"

			"""
		for p in platforms {
			guard let dest = destinations[p] else { continue }
			s += """
				t0=$(perl -MTime::HiRes=time -e 'printf "%.1f", time')
				xcodebuild build -scheme WarmUp -destination '\(dest)' -quiet >/tmp/cryo-warmup-\(p).log 2>&1; rc=$?
				t1=$(perl -MTime::HiRes=time -e 'printf "%.1f", time')
				echo "warm-up \(p): $(perl -e "printf '%.1f', $t1 - $t0") s rc=$rc"

				"""
		}
		s += """
			cd /
			rm -rf "$W" ~/Library/Developer/Xcode/DerivedData/WarmUp-*
			ls ~/Library/Developer/Xcode/DerivedData/
			"""
		return s
	}

	/// Parses `--warm-up ios,macos` (bare `--warm-up` = iOS).
	static func platforms(_ value: String?) throws -> [String] {
		let list = (value ?? "ios").split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
		for p in list where destinations[p] == nil {
			throw BayError("--warm-up takes ios, macos or ios,macos (got \(p))")
		}
		return list
	}

	@MainActor
	static func run(_ guest: Guest, platforms: [String], out: BayCommand.Writer) async throws {
		let r = await guest.ssh("/bin/zsh -s", stdin: Data(script(platforms: platforms).utf8), timeout: nil)
		for line in r.out.split(separator: "\n") where line.hasPrefix("warm-up") { out("\(line)\n") }
		let lines = r.out.split(separator: "\n").filter { $0.hasPrefix("warm-up") }
		guard r.status == 0, lines.count == platforms.count, lines.allSatisfy({ $0.hasSuffix("rc=0") }) else {
			throw BayError("warm-up build failed (status \(r.status)): \(r.out.suffix(400))")
		}
		guard r.out.contains("SDKExplicitPrecompiledModules") || r.out.contains("ModuleCache.noindex") else {
			throw BayError("warm-up left no shared module caches: \(r.out.suffix(400))")
		}
	}
}

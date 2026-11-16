// swift-tools-version: 6.0
import PackageDescription

let package = Package(
	name: "cryo",
	platforms: [.macOS("27.0")],
	products: [
		.executable(name: "cryo", targets: ["cryo"]),
		// Used by cryo-ci: the API types, the client, the HTTP and thread helpers, and
		// the in-process fake bay its tests run against.
		.library(name: "CryoAPI", targets: ["CryoAPI"]),
		.library(name: "CryoHTTP", targets: ["CryoHTTP"]),
		.library(name: "CryoClient", targets: ["CryoClient"]),
		.library(name: "FakeBay", targets: ["FakeBay"]),
	],
	targets: [
		.target(name: "CryoAPI"),
		.target(name: "CryoHTTP"),
		.target(name: "CryoClient", dependencies: ["CryoAPI", "CryoHTTP"]),
		.target(name: "FakeBay", dependencies: ["CryoAPI", "CryoHTTP"]),
		// macOS only: the bay drives Virtualization.framework. Linux builds leave it out.
		.target(name: "CryoBay", dependencies: ["CryoAPI", "CryoHTTP"]),
		.target(
			name: "CryoCLI",
			dependencies: [
				"CryoAPI", "CryoHTTP", "CryoClient", "CryoMCP",
				.target(name: "CryoBay", condition: .when(platforms: [.macOS])),
			]),
		.target(name: "CryoMCP", dependencies: ["CryoAPI", "CryoHTTP", "CryoClient"]),
		.executableTarget(name: "cryo", dependencies: ["CryoCLI"]),
		.testTarget(name: "CryoAPITests", dependencies: ["CryoAPI"]),
		.testTarget(name: "CryoHTTPTests", dependencies: ["CryoHTTP"]),
		.testTarget(name: "CryoCLITests", dependencies: ["CryoAPI", "CryoHTTP", "CryoClient", "CryoCLI", "FakeBay"]),
		.testTarget(name: "CryoMCPTests", dependencies: ["CryoAPI", "CryoHTTP", "CryoClient", "CryoMCP", "FakeBay"]),
		.testTarget(name: "CryoBayTests", dependencies: ["CryoBay", "CryoAPI", "CryoHTTP", "CryoClient", "FakeBay"]),
		.testTarget(name: "CryoClientTests", dependencies: ["CryoAPI", "CryoHTTP", "CryoClient", "FakeBay"]),
	],
	swiftLanguageModes: [.v6]
)

#if os(Linux)
	// Neither the bay nor its tests can import Apple's host frameworks on Linux.
	package.targets.removeAll { $0.name == "CryoBay" || $0.name == "CryoBayTests" }
	for target in package.targets {
		target.dependencies.removeAll {
			switch $0 {
			case .targetItem(name: "CryoBay", condition: _), .byNameItem(name: "CryoBay", condition: _): return true
			default: return false
			}
		}
	}
#endif

import Foundation
import Testing

@testable import CryoBay

@Suite struct ImageBuildTests {
	/// Two epochs, a newer build for a real Mac only, and 27.10 vs 27.9 (string order would pick 27.9).
	@Test func picksNewestVirtualMacRestoreImage() throws {
		func restore(_ v: String, _ b: String) -> [String: Any] {
			["Restore": ["ProductVersion": v, "BuildVersion": b, "FirmwareURL": "https://updates.cdn-apple.com/x/UniversalMac_\(v)_\(b)_Restore.ipsw"]]
		}
		let catalog: [String: Any] = [
			"MobileDeviceProductTypes": [:] as [String: Any],
			"MobileDeviceSoftwareVersionsByVersion": [
				"1": [
					"MobileDeviceSoftwareVersions": [
						"VirtualMac2,1": ["26B123": restore("27.9", "26B123")],
						"Macmini9,1": ["27A1": restore("28.0", "27A1")],
					]
				],
				"2": [
					"MobileDeviceSoftwareVersions": [
						"VirtualMac2,1": ["26C10": restore("27.10", "26C10"), "26A5": restore("27.1", "26A5")]
					]
				],
			],
		]
		let data = try PropertyListSerialization.data(fromPropertyList: catalog, format: .xml, options: 0)
		let r = try ImageBuild.latest(catalog: data)
		#expect(r.version == "27.10")
		#expect(r.build == "26C10")
		#expect(r.url.lastPathComponent == "UniversalMac_27.10_26C10_Restore.ipsw")
	}

	@Test func readsXcodeVersion() {
		#expect(ImageBuild.xcodeVersion("Xcode 27.2\nBuild version 27B52\n") == "27.2 (27B52)")
		#expect(ImageBuild.xcodeVersion("== Disk Images ==\n") == nil)
	}
}

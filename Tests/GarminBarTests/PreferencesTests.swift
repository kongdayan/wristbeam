import XCTest
@testable import GarminBar

final class PreferencesTests: XCTestCase {
    func testPersistentDomainKeepsOtherSettingsAndSupportsDirectLaunch() {
        let domain = "cn.wenyankong.garminpulse.test.\(UUID().uuidString)"
        defer { UserDefaults.standard.removePersistentDomain(forName: domain) }
        let preferences = AppPreferences(domain: domain)
        preferences.set("saved-watch", forKey: "watchIdentifier")
        preferences.set(true, forKey: "autoSync")
        preferences.set(Data([1, 2, 3]), forKey: "bookmark")
        let restored = AppPreferences(domain: domain)
        XCTAssertEqual(restored.string(forKey: "watchIdentifier"), "saved-watch")
        XCTAssertTrue(restored.bool(forKey: "autoSync"))
        XCTAssertEqual(restored.data(forKey: "bookmark"), Data([1, 2, 3]))
        restored.removeObject(forKey: "bookmark")
        XCTAssertNil(preferences.data(forKey: "bookmark"))
        XCTAssertEqual(preferences.string(forKey: "watchIdentifier"), "saved-watch")
    }
}

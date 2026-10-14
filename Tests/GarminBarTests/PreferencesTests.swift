import XCTest
@testable import GarminBar

final class PreferencesTests: XCTestCase {
    func testFreshProfileKeepsManualSyncAfterPairingAndRestart() {
        let domain = "cn.wenyankong.garminpulse.test.\(UUID().uuidString)"
        defer { UserDefaults.standard.removePersistentDomain(forName: domain) }
        let preferences = AppPreferences(domain: domain)
        preferences.prepareSetupDefaults()
        XCTAssertFalse(preferences.bool(forKey: "autoSync"))
        XCTAssertFalse(preferences.bool(forKey: "floatingEnabled"))
        preferences.set(UUID().uuidString, forKey: "watchIdentifier")
        let restarted = AppPreferences(domain: domain)
        restarted.prepareSetupDefaults()
        XCTAssertFalse(restarted.bool(forKey: "autoSync"))
        XCTAssertFalse(restarted.bool(forKey: "watchConnectOnLaunch"))
    }
    func testLegacyDefaultsSurviveUpgradeWithoutEnablingLaunchConnection() {
        let domain = "cn.wenyankong.garminpulse.test.\(UUID().uuidString)"
        defer { UserDefaults.standard.removePersistentDomain(forName: domain) }
        let preferences = AppPreferences(domain: domain), watch = UUID().uuidString
        preferences.set(watch, forKey: "watchIdentifier")
        preferences.prepareSetupDefaults()
        XCTAssertTrue(preferences.bool(forKey: "autoSync"))
        XCTAssertTrue(preferences.bool(forKey: "floatingEnabled"))
        XCTAssertFalse(preferences.bool(forKey: "watchConnectOnLaunch"))
        XCTAssertEqual(preferences.string(forKey: "watchIdentifier"), watch)
    }
    func testSetupMigrationPreservesExplicitChoices() {
        let domain = "cn.wenyankong.garminpulse.test.\(UUID().uuidString)"
        defer { UserDefaults.standard.removePersistentDomain(forName: domain) }
        let preferences = AppPreferences(domain: domain)
        preferences.set(UUID().uuidString, forKey: "watchIdentifier")
        preferences.set(false, forKey: "autoSync")
        preferences.set(false, forKey: "floatingEnabled")
        preferences.set(true, forKey: "watchConnectOnLaunch")
        preferences.prepareSetupDefaults()
        XCTAssertFalse(preferences.bool(forKey: "autoSync"))
        XCTAssertFalse(preferences.bool(forKey: "floatingEnabled"))
        XCTAssertTrue(preferences.bool(forKey: "watchConnectOnLaunch"))
    }
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

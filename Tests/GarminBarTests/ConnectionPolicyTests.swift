import XCTest
@testable import GarminBar

final class ConnectionPolicyTests: XCTestCase {
    func testStartupDoesNotAskForUndeterminedBluetoothAccessEvenWithOptIn() {
        XCTAssertFalse(ConnectionStartupPolicy.canConnect(automatically: true, savedWatch: true, access: .notDetermined, preview: false))
    }
    func testAuthorizedSavedWatchStillNeedsExplicitLaunchOptIn() {
        XCTAssertFalse(ConnectionStartupPolicy.canConnect(automatically: false, savedWatch: true, access: .allowed, preview: false))
    }
    func testDeniedOrRestrictedAccessNeverStartsAConnection() {
        for access in [BluetoothAccess.denied, .restricted] {
            XCTAssertFalse(ConnectionStartupPolicy.canConnect(automatically: true, savedWatch: true, access: access, preview: false))
        }
    }
    func testOptInDoesNotScanForAnUnsavedWatchAtLaunch() {
        XCTAssertFalse(ConnectionStartupPolicy.canConnect(automatically: true, savedWatch: false, access: .allowed, preview: false))
    }
    func testPreviewCannotActivateBluetoothWithAnOptIn() {
        XCTAssertFalse(ConnectionStartupPolicy.canConnect(automatically: true, savedWatch: true, access: .allowed, preview: true))
    }
    func testExplicitOptInCanRestoreAnAuthorizedSavedWatch() {
        XCTAssertTrue(ConnectionStartupPolicy.canConnect(automatically: true, savedWatch: true, access: .allowed, preview: false))
    }
}

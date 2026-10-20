import Foundation
import XCTest
@testable import GarminBar

final class ConnectIQModelsTests: XCTestCase {
    private let appID = "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"

    func testKeywordInputPreservesUnicodeAndRejectsInvalidOrOversizeQueries() {
        XCTAssertEqual(ConnectIQService.searchKeywords(from: "  山水 Digital + A&B  "), "山水 Digital + A&B")
        XCTAssertNotNil(ConnectIQService.searchKeywords(from: String(repeating: "山", count: 128)))
        for input in ["", " \n ", String(repeating: "a", count: 129), "a\nb", "a\u{0}b", "https://example.org/face"] {
            XCTAssertNil(ConnectIQService.searchKeywords(from: input))
        }
    }

    func testMediaUsesRegionalPublicHostAndRejectsNonUUIDPaths() throws {
        XCTAssertEqual(ConnectIQService.imageURL(fileID: appID, kind: "icons", region: .china)?.absoluteString,
                       "https://services.garmin.cn/appstore/api/icons/\(appID)")
        XCTAssertNil(ConnectIQService.imageURL(fileID: "../secret", kind: "icons", region: .china))
        XCTAssertNil(ConnectIQService.imageURL(fileID: appID, kind: "../packages", region: .china))
        let app = try ConnectIQApp.parse(["id": appID, "latestInternalVersion": 1,
                                        "appLocalizations": [["name": "Test"]],
                                        "iconFileId": appID, "screenshotFileIds": [appID, "invalid"]])
        XCTAssertNotNil(app.iconURL)
        XCTAssertEqual(app.screenshotURLs.count, 1)
    }

    func testAppIDAcceptsUUIDAndOfficialStoreLinksOnly() {
        XCTAssertEqual(ConnectIQService.appID(from: "  \(appID.uppercased())\n"), appID)
        for host in ["apps.garmin.cn", "apps.garmin.com"] {
            XCTAssertEqual(ConnectIQService.appID(from: "https://\(host)/en-US/apps/\(appID)?tab=reviews"), appID)
        }
        for input in ["not-an-id", "http://apps.garmin.cn/apps/\(appID)",
                      "https://apps.garmin.cn.example.org/apps/\(appID)",
                      "https://example.org/apps/\(appID)", "https://user@apps.garmin.cn/apps/\(appID)",
                      "https://apps.garmin.cn:444/apps/\(appID)", "https://apps.garmin.cn/apps/\(appID)/install"] {
            XCTAssertNil(ConnectIQService.appID(from: input), input)
        }
    }

    func testDetailsPreferChineseLocalizationAndNormalizeIdentifiers() throws {
        let original = L10n.language; defer { L10n.language = original }
        L10n.language = .zhHans
        let app = try ConnectIQApp.parse([
            "id": appID.uppercased(), "latestInternalVersion": 7, "latestExternalVersion": "1.7",
            "appLocalizations": [["locale": "en-US", "name": "Synthetic"],
                                 ["locale": "zh_CN", "name": "合成表盘", "description": "测试说明"]],
            "typeId": 1, "compatibleDevicePartNumbers": ["006-B9999-00"],
            "permissions": ["Sensor"], "paymentModel": 2, "hasTrialMode": true
        ])
        XCTAssertEqual(app.id, appID); XCTAssertEqual(app.name, "合成表盘")
        XCTAssertEqual(app.description, "测试说明"); XCTAssertEqual(app.version, "1.7")
        XCTAssertEqual(app.internalVersion, 7); XCTAssertTrue(app.isWatchFace)
        XCTAssertEqual(app.compatiblePartNumbers, ["006-B9999-00"])
        XCTAssertEqual(app.permissions, ["Sensor"]); XCTAssertEqual(app.paymentModel, 2)
        XCTAssertTrue(app.hasTrialMode)
    }

    func testStoreTextsSwitchLanguageWithoutRefetching() throws {
        let original = L10n.language; defer { L10n.language = original }
        L10n.language = .en
        let app = try ConnectIQApp.parse([
            "id": appID, "latestInternalVersion": 1,
            "appLocalizations": [
                ["locale": "zh_CN", "name": "山间", "description": "中文介绍"],
                ["locale": "ja-JP", "name": "日本語"],
                ["locale": "en_US", "name": "Mountain", "description": "English description"]]])
        XCTAssertEqual(app.name, "Mountain")
        XCTAssertEqual(app.localizedDescription, "English description")
        L10n.language = .zhHans
        XCTAssertEqual(app.localizedName, "山间")
        XCTAssertEqual(app.localizedDescription, "中文介绍")
        L10n.language = .en
        XCTAssertEqual(app.localizedName, "Mountain")
        XCTAssertEqual(app.localizedDescription, "English description")
    }

    func testStoreTextsFallBackToEnglishThenAvailableOriginal() throws {
        let original = L10n.language; defer { L10n.language = original }
        let english = try ConnectIQApp.parse([
            "id": appID, "latestInternalVersion": 1,
            "appLocalizations": [["locale": "ja", "name": "Original"],
                                 ["locale": "en-GB", "name": "English"]]])
        for language in [PulseLanguage.zhHans, .en] {
            L10n.language = language
            XCTAssertEqual(english.localizedName, "English")
        }
        let chineseOnly = try ConnectIQApp.parse([
            "id": appID, "latestInternalVersion": 1,
            "appLocalizations": [["locale": "zh-CN", "name": "原名", "description": "作者原文"]]])
        XCTAssertEqual(chineseOnly.localizedName, "原名")
        XCTAssertEqual(chineseOnly.localizedDescription, "作者原文")
    }

    func testStoreLocalizationsRoundTripAndLegacySnapshotsStillDecode() throws {
        let original = L10n.language; defer { L10n.language = original }
        L10n.language = .en
        let app = try ConnectIQApp.parse([
            "id": appID, "latestInternalVersion": 1,
            "appLocalizations": [["locale": "en-US", "name": "English"], ["locale": "zh-CN", "name": "中文"]]])
        let data = try JSONEncoder().encode(app)
        let restored = try JSONDecoder().decode(ConnectIQApp.self, from: data)
        L10n.language = .zhHans
        XCTAssertEqual(restored.localizedName, "中文")
        var legacy = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        legacy.removeValue(forKey: "localizations")
        let old = try JSONDecoder().decode(ConnectIQApp.self, from: JSONSerialization.data(withJSONObject: legacy))
        XCTAssertEqual(old.localizedName, "English")
    }

    func testDetailsRejectIncompleteOrMalformedIdentityAndVersion() {
        let valid: [String: Any] = ["id": appID, "latestInternalVersion": 1,
                                    "appLocalizations": [["name": "Synthetic"]]]
        for (key, value) in [("id", "bogus" as Any), ("latestInternalVersion", 0 as Any),
                             ("latestInternalVersion", "1" as Any), ("appLocalizations", [] as Any)] {
            var invalid = valid; invalid[key] = value
            XCTAssertThrowsError(try ConnectIQApp.parse(invalid))
        }
        XCTAssertThrowsError(try ConnectIQApp.parse(Data("[]".utf8)))
    }

    func testHistoryUsesMillisecondsAndRejectsMalformedRows() throws {
        let row: [String: Any] = ["appId": appID.uppercased(), "internalAppVersion": 7, "date": 120_000]
        let rows = try ConnectIQDownloadRecord.parse(JSONSerialization.data(withJSONObject: [row]))
        XCTAssertEqual(rows.count, 1); XCTAssertEqual(rows[0].appID, appID)
        XCTAssertEqual(rows[0].version, "7"); XCTAssertEqual(rows[0].date.timeIntervalSince1970, 120)
        var invalid = row; invalid["appId"] = "malformed"
        XCTAssertThrowsError(try ConnectIQDownloadRecord.parse(JSONSerialization.data(withJSONObject: [row, invalid])))
        invalid = row; invalid["internalAppVersion"] = -1
        XCTAssertThrowsError(try ConnectIQDownloadRecord.parse(JSONSerialization.data(withJSONObject: [invalid])))
        XCTAssertThrowsError(try ConnectIQDownloadRecord.parse(Data("{}".utf8)))
    }

    func testQueueSelectsOnlyRequestedDeviceAppAndInstallType() throws {
        let wrongApp = message(appID: "11111111-2222-3333-4444-555555555555")
        let wrongDevice = message(deviceID: "202")
        var wrongType = message(); wrongType["messageType"] = "delete_app"
        let data = try queue([wrongApp, wrongDevice, wrongType, message()])
        let url = try ConnectIQService.packageURL(data, appID: appID, deviceID: "101", region: .china)
        XCTAssertEqual(url?.absoluteString, "https://connectapi.garmin.cn/packages/synthetic.prg")
        XCTAssertNil(try ConnectIQService.packageURL(queue([wrongApp, wrongDevice, wrongType]), appID: appID, deviceID: "101", region: .china))
    }

    func testRelativeQueueURLIgnoresUntrustedServiceHost() throws {
        let data = try JSONSerialization.data(withJSONObject: [
            "serviceHost": "https://example.org/steal", "messages": [message()]
        ])
        let url = try ConnectIQService.packageURL(data, appID: appID, deviceID: "101", region: .china)
        XCTAssertEqual(url?.absoluteString, "https://connectapi.garmin.cn/packages/synthetic.prg")
    }

    func testQueueRejectsUntrustedCrossRegionAndCredentialBearingURLs() throws {
        for url in ["https://example.org/file", "https://services.garmin.cn.example.org/file",
                    "https://services.garmin.com/file", "https://sso.garmin.cn/file",
                    "http://services.garmin.cn/file", "https://user@services.garmin.cn/file",
                    "https://services.garmin.cn:444/file", "//example.org/file"] {
            XCTAssertThrowsError(try ConnectIQService.packageURL(queue([message(url: url)]), appID: appID, deviceID: "101", region: .china)) {
                XCTAssertEqual($0 as? ConnectIQError, .downloadHostUnsupported, url)
            }
        }
        XCTAssertThrowsError(try ConnectIQService.packageURL(Data("{}".utf8), appID: appID, deviceID: "101", region: .china))
    }

    func testPackageRejectsTextErrorsEmptyAndOversizedPayloads() throws {
        let binary = Data([0xD0, 0x00, 0xAB, 0x12])
        XCTAssertNoThrow(try ConnectIQService.validatePackage(binary, contentType: "application/octet-stream"))
        for type in ["application/json", "text/html", "text/plain", "application/problem+json"] {
            XCTAssertThrowsError(try ConnectIQService.validatePackage(binary, contentType: type))
        }
        for text in ["  <html>Error</html>", "\n{\"error\":true}", "[\"error\"]"] {
            XCTAssertThrowsError(try ConnectIQService.validatePackage(Data(text.utf8), contentType: "application/octet-stream"))
        }
        XCTAssertThrowsError(try ConnectIQService.validatePackage(Data(), contentType: nil))
        XCTAssertThrowsError(try ConnectIQService.validatePackage(Data(count: ConnectIQService.maximumPackageBytes + 1), contentType: nil))
    }

    private func message(appID: String? = nil, deviceID: String = "101", url: String = "/packages/synthetic.prg") -> [String: Any] {
        ["messageType": "install_app", "deviceId": deviceID,
         "metaData": ["appDetails": ["id": appID ?? self.appID], "messageUrl": url]]
    }
    private func queue(_ messages: [[String: Any]]) throws -> Data {
        try JSONSerialization.data(withJSONObject: ["serviceHost": "https://services.garmin.cn", "messages": messages])
    }
}

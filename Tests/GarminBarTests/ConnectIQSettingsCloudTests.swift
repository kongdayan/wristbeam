import Foundation
import XCTest
@testable import GarminBar

final class ConnectIQSettingsCloudTests: XCTestCase {
    private let appID = "00112233-4455-6677-8899-aabbccddeeff"

    func testEditorLanguageIsIndependentOfAccountRegion() throws {
        let original = L10n.language; defer { L10n.language = original }
        for region in [GarminRegion.china, .global] {
            for language in [PulseLanguage.zhHans, .en] {
                L10n.language = language
                let tag = language == .en ? "en-US" : "zh-CN"
                let context = try ConnectIQSettingsContext(appID: appID, version: 1, partNumber: "006-B9999-00", region: region, locale: L10n.languageTag)
                let request = try context.editorRequest(settingsJSON: Data("{}".utf8), dark: false)
                XCTAssertEqual(request.url?.host, "apps.\(region.domain)")
                XCTAssertTrue(request.url!.path.hasPrefix("/\(tag)/"))
                XCTAssertTrue(context.binaryURL.path.hasPrefix("/\(tag)/"))
            }
        }
    }

    func testEditorPreservesUnicodePlusAndUnknownNestedPropertiesWithoutAuth() throws {
        let context = try ConnectIQSettingsContext(appID: appID, version: 7, partNumber: "006-B9999-00", region: .china, locale: "zh-CN")
        let original: [String: Any] = ["text": "中文 + & = % ? #", "nested": ["keep": [1, true, "a+b"]]]
        let json = try JSONSerialization.data(withJSONObject: original, options: [.sortedKeys])
        let request = try context.editorRequest(settingsJSON: json, dark: true)
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.url?.host, "apps.garmin.cn")
        XCTAssertTrue(request.url!.path.contains("/versions/7/devices/006-B9999-00/"))
        XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
        XCTAssertNil(request.value(forHTTPHeaderField: "Cookie"))
        let body = try XCTUnwrap(String(data: try XCTUnwrap(request.httpBody), encoding: .utf8))
        XCTAssertFalse(body.contains("中文"))
        let encoded = String(body.dropFirst("userSettings=".count))
        let decoded = try XCTUnwrap(encoded.replacingOccurrences(of: "+", with: " ").removingPercentEncoding)
        XCTAssertEqual(Data(decoded.utf8), json)
        XCTAssertFalse(request.url!.absoluteString.contains("userSettings"))
    }

    func testSerializerUsesSameInstalledVersionAndDoesNotFlattenValues() throws {
        let context = try ConnectIQSettingsContext(appID: appID, version: 12, partNumber: "006-B9999-00", region: .global, locale: "en-US")
        let json = Data(#"{"list":[{"value":"a+b","enabled":"off"}],"readonly":"preserved"}"#.utf8)
        let request = try context.binaryRequest(settingsJSON: json)
        XCTAssertEqual(request.url?.host, "apps.garmin.com")
        XCTAssertEqual(request.url?.path, "/en-US/appSettings2/\(appID)/versions/12/devices/006-B9999-00/binary")
        XCTAssertEqual(request.httpBody, json)
        XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
    }

    func testInvalidContextsAndNonObjectOrOversizePayloadsAreRejected() throws {
        XCTAssertThrowsError(try ConnectIQSettingsContext(appID: "../escape", version: 1, partNumber: "006-B9999-00", region: .china, locale: "zh-CN"))
        XCTAssertThrowsError(try ConnectIQSettingsContext(appID: appID, version: 0, partNumber: "006-B9999-00", region: .china, locale: "zh-CN"))
        XCTAssertThrowsError(try ConnectIQSettingsContext(appID: appID, version: 1, partNumber: "../other", region: .china, locale: "zh-CN"))
        XCTAssertThrowsError(try ConnectIQSettingsContext(appID: appID, version: 1, partNumber: "006-B9999-00", region: .china, locale: "en-US/../../"))
        let context = try ConnectIQSettingsContext(appID: appID, version: 1, partNumber: "006-B9999-00", region: .china, locale: "zh-CN")
        XCTAssertThrowsError(try context.binaryRequest(settingsJSON: Data("[]".utf8)))
        XCTAssertThrowsError(try context.binaryRequest(settingsJSON: Data("<html>error</html>".utf8)))
        XCTAssertThrowsError(try context.binaryRequest(settingsJSON: Data(repeating: 32, count: ConnectIQSettingsContext.maximumBytes + 1)))
    }
}

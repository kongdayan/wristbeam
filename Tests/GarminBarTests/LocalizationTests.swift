import XCTest
@testable import GarminBar

final class LocalizationTests: XCTestCase {
    func testLanguageSwitchUpdatesMetricNamesWithoutChangingStoredIDs() {
        let original = L10n.language; defer { L10n.language = original }
        L10n.language = .en
        XCTAssertEqual(MetricKind.heartRate.title, "Heart rate")
        XCTAssertEqual(MetricKind.steps.unit, "steps")
        XCTAssertEqual(L10n.text("显示设置"), "Display settings")
        XCTAssertEqual(L10n.text("佳明中国账户已连接"), "Garmin China account connected")
        XCTAssertEqual(MetricKind.heartRate.rawValue, "heartRate")
        L10n.language = .zhHans
        XCTAssertEqual(MetricKind.heartRate.title, "心率")
        XCTAssertEqual(L10n.text("已刷新 51 项云端同步指标"), "已刷新 51 项云端同步指标")
    }
    func testDynamicMessagesAndCatalogPreservePlaceholders() {
        let original = L10n.language; defer { L10n.language = original }
        L10n.language = .en
        XCTAssertEqual(L10n.text("已刷新 51 项云端同步指标"), "Refreshed 51 cloud metrics")
        XCTAssertEqual(L10n.text("太阳能强度 ≥ 20%"), "Solar intensity ≥ 20%")
        XCTAssertEqual(L10n.format("查看{0}全天趋势", "心率"), "View Heart rate daily trend")
        for metric in MetricKind.allCases { XCTAssertFalse(metric.title.range(of: "\\p{Han}", options: .regularExpression) != nil) }
    }
}

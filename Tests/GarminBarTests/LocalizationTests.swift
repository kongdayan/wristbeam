import XCTest
@testable import GarminBar

final class LocalizationTests: XCTestCase {
    func testSystemUsesChineseOnlyForChinesePrimaryLanguage() {
        for language in ["zh", "zh-Hans-CN", "zh-Hant-TW", "ZH_HK"] {
            XCTAssertEqual(PulseLanguage.system.resolved(preferredLanguages: [language, "en"]), .zhHans)
        }
        for language in ["en-US", "ja-JP", "ko-KR", "ru-RU", "fr-FR", "de-DE"] {
            XCTAssertEqual(PulseLanguage.system.resolved(preferredLanguages: [language, "zh-CN"]), .en)
        }
        XCTAssertEqual(PulseLanguage.system.resolved(preferredLanguages: []), .en)
        XCTAssertEqual(PulseLanguage.zhHans.resolved(preferredLanguages: ["ja-JP"]), .zhHans)
        XCTAssertEqual(PulseLanguage.en.resolved(preferredLanguages: ["zh-CN"]), .en)
    }

    func testConnectIQControlsAndStatusesSwitchBetweenChineseAndEnglish() {
        let original = L10n.language; defer { L10n.language = original }
        let keys = ["搜索表盘名称、关键词或粘贴链接", "搜索结果", "未找到匹配的表盘，试试其他关键词",
                    "保存到手表", "正在读取手表当前配置", "手表已确认安装", "文件已传完，手表安装尚未确认，请重新读取"]
        L10n.language = .zhHans
        XCTAssertEqual(L10n.languageTag, "zh-CN")
        for key in keys { XCTAssertEqual(L10n.text(key), key) }
        L10n.language = .en
        XCTAssertEqual(L10n.languageTag, "en-US")
        for key in keys {
            XCTAssertNotEqual(L10n.text(key), key)
            XCTAssertNil(L10n.text(key).range(of: "\\p{Han}", options: .regularExpression))
        }
    }

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

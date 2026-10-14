import XCTest
@testable import GarminBar

final class DisplayTests: XCTestCase {
    func testUnavailableMetricsStayOutAndSelectionsKeepTheirStableIDs() {
        let available = MetricLayout.available(readings: [.heartRate, .solarIntensity], registered: [.bodyBattery], discovered: [.stress])
        XCTAssertEqual(available, [.heartRate, .solarIntensity])
        XCTAssertFalse(available.contains(.bodyBattery))
        XCTAssertFalse(available.contains(.watchBattery))
        XCTAssertFalse(available.contains(MetricKind(rawValue: "pushes")!))
        XCTAssertEqual(MetricDestination.allCases.map(\.rawValue), ["dashboard", "floating", "menu"])
    }
    func testSummaryLinksOpenRelatedTrendAndNeverAnArbitrarySolarChart() {
        for id in ["daily.restingHeartRate", "daily.lastSevenDaysAvgRestingHeartRate", "daily.minHeartRate", "daily.maxHeartRate"] { XCTAssertEqual(MetricKind(rawValue: id)!.relatedTrend, .heartRate) }
        XCTAssertEqual(MetricKind(rawValue: "daily.bodyBatteryChargedValue")!.relatedTrend, .bodyBattery)
        XCTAssertEqual(MetricKind(rawValue: "daily.maxStressLevel")!.relatedTrend, .stress)
        XCTAssertEqual(MetricKind(rawValue: "daily.dailyStepGoal")!.relatedTrend, .steps)
        XCTAssertNil(MetricKind(rawValue: "daily.sleepingSeconds")!.relatedTrend)
    }
    func testGroupingKeepsEveryMetricExactlyOnce() {
        let grouped = MetricCategory.allCases.flatMap(\.metrics)
        XCTAssertEqual(Set(grouped), Set(MetricKind.allCases.filter { !$0.isDeviceStatus }))
        XCTAssertEqual(grouped.count, MetricKind.allCases.count - 1)
        XCTAssertEqual(MetricKind.solarIntensity.category, .solar)
        XCTAssertEqual(MetricKind(rawValue: "daily.restingHeartRate")!.category, .heart)
        XCTAssertEqual(MetricKind(rawValue: "daily.sleepingSeconds")!.category, .sleep)
    }
    func testCustomOrderRetainsSelectionAndRejectsUnknownOrDuplicateItems() {
        let selection: Set<MetricKind> = [.heartRate, .stress, .steps, .solarIntensity]
        let order = ["solarIntensity", "deleted.metric", "solarIntensity", "bodyBattery", "stress"]
        let result = MetricLayout.ordered(selection: selection, order: order)
        XCTAssertEqual(result, [.solarIntensity, .stress, .heartRate, .steps])
        let moved = MetricLayout.moving(.steps, before: .solarIntensity, in: result)
        XCTAssertEqual(MetricLayout.ordered(selection: selection, order: moved), [.steps, .solarIntensity, .stress, .heartRate])
    }
    func testIndependentSelectionsPreserveExplicitEmptyAndLegacyFallback() {
        let prefix = "display-test-\(UUID().uuidString)"
        let keys = [prefix + ".dashboard", prefix + ".floating", prefix + ".widget"]
        defer { keys.forEach { AppPreferences.shared.removeObject(forKey: $0) } }
        AppPreferences.shared.set([], forKey: keys[0])
        AppPreferences.shared.set(["steps", "solarIntensity", "unknown"], forKey: keys[1])
        XCTAssertEqual(MetricLayout.selected(keys[0], fallback: [.heartRate]), [])
        XCTAssertEqual(MetricLayout.selected(keys[1], fallback: [.heartRate]), [.steps, .solarIntensity])
        XCTAssertEqual(MetricLayout.selected(keys[2], fallback: [.bodyBattery]), [.bodyBattery])
    }
    func testWatchBatteryIsDeviceStatusWithoutHealthSelectionOrTimeline() {
        XCTAssertTrue(MetricKind.watchBattery.isDeviceStatus)
        XCTAssertNil(MetricKind.watchBattery.timelineKind)
        XCTAssertNil(MetricKind.watchBattery.relatedTrend)
        XCTAssertFalse(MetricKind.watchBattery.acceptsLiveTimeline)
        XCTAssertEqual(MetricLayout.available(readings: [.heartRate, .watchBattery], registered: [.watchBattery], discovered: [.watchBattery]), [.heartRate])
        XCTAssertEqual(MetricLayout.ordered(selection: [.watchBattery, .heartRate], order: ["watchBattery", "heartRate"]), [.heartRate])
        let key = "battery-selection-\(UUID().uuidString)"
        defer { AppPreferences.shared.removeObject(forKey: key) }
        XCTAssertEqual(MetricLayout.selected(key, fallback: [.watchBattery, .bodyBattery]), [.bodyBattery])
        AppPreferences.shared.set(["watchBattery", "steps"], forKey: key)
        XCTAssertEqual(MetricLayout.selected(key, fallback: []), [.steps])
    }
}

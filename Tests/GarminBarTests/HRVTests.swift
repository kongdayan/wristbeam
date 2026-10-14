import XCTest
@testable import GarminBar

final class HRVTests: XCTestCase {
    private let now = GarminHRV.date("2026-10-14")!.addingTimeInterval(43200)
    func testHistoryKeepsMissingWeeklyAndBaselineMissing() throws {
        let data = Data(#"{"hrvSummaries":[{"calendarDate":"2026-10-13","lastNightAvg":48,"weeklyAvg":null,"lastNight5MinHigh":72,"status":"NONE","baseline":{"balancedLow":null,"balancedUpper":null}}]}"#.utf8)
        let rows = try GarminHRV.history(data, now: now)
        XCTAssertEqual(rows.count, 1); XCTAssertNil(rows[0].weekly); XCTAssertNil(rows[0].baselineLow)
        XCTAssertEqual(rows[0].status, GarminHRVStatus.none)
        let report = GarminHRVReport(summaries: rows, nights: [:], refreshedAt: now)
        XCTAssertFalse(report.samples.contains { $0.kind == .hrvWeekly })
        XCTAssertEqual(report.samples.first { $0.kind == .hrvNight }?.timestamp, GarminHRV.date("2026-10-13"))
    }
    func testRejectsBooleanNonpositiveFutureAndInvalidDateValues() throws {
        XCTAssertNil(GarminHRV.number(true)); XCTAssertNil(GarminHRV.number(-1)); XCTAssertNil(GarminHRV.number(0)); XCTAssertNil(GarminHRV.number(Double.infinity))
        XCTAssertNil(GarminHRV.date("2026-02-31"))
        XCTAssertNil(GarminHRV.summary(["calendarDate":"2027-01-01","lastNightAvg":42], now: now))
        let row = GarminHRV.summary(["calendarDate":"2026-10-13", "lastNightAvg":true,"weeklyAvg":-1,"baseline":["balancedLow":80,"balancedUpper":40]], now: now)
        XCTAssertNil(row?.night); XCTAssertNil(row?.weekly); XCTAssertNil(row?.baselineHigh)
    }
    func testNightRetainsCrossMidnightAndMissingReadings() throws {
        let day = GarminHRV.date("2026-10-14")!
        let stamp = ISO8601DateFormatter()
        let before = stamp.string(from: day.addingTimeInterval(-3600)), after = stamp.string(from: day.addingTimeInterval(3600))
        let object: [String:Any] = ["hrvSummary":["calendarDate":"2026-10-14","lastNightAvg":48],"hrvReadings":[["readingTimeGMT":before,"hrvValue":50],["readingTimeGMT":after,"hrvValue":-1]]]
        let (_, readings) = try GarminHRV.night(JSONSerialization.data(withJSONObject: object), expectedDay: day, now: now)
        XCTAssertEqual(readings.count, 2); XCTAssertTrue(readings[0].timestamp < day); XCTAssertNil(readings[1].value)
        XCTAssertThrowsError(try GarminHRV.night(JSONSerialization.data(withJSONObject: object), expectedDay: day.addingTimeInterval(-86400), now: now))
    }
    func testCloudStatusDoesNotBecomeRRAndUnknownIsNotBalanced() {
        XCTAssertNil(GarminHRVStatus(wire:"NEW_UNKNOWN_STATUS"))
        XCTAssertEqual(GarminHRVStatus(wire:"UNBALANCED_LOW"), .unbalancedLow)
        XCTAssertNotEqual(MetricKind.hrvNight.rawValue, "hrv")
        XCTAssertNil(MetricKind.hrvNight.definition.service)
        XCTAssertEqual(MetricKind(rawValue:"hrv")?.definition.service, 12)
        XCTAssertNil(MetricKind.hrvStatus.relatedTrend)
        XCTAssertEqual(MetricKind.hrvNight.category, .heart)
    }
    func testLatestWithDataSkipsEmptyTodayWithoutInventingAnAverage() {
        let yesterday = GarminHRVSummary(day: now.addingTimeInterval(-86400), night: 50, weekly: nil, high: 80, status: GarminHRVStatus.none)
        let today = GarminHRVSummary(day: now, status: GarminHRVStatus.none)
        let report = GarminHRVReport(summaries:[yesterday,today], nights:[:], refreshedAt:now)
        XCTAssertEqual(report.latest?.day, yesterday.day)
        XCTAssertNil(report.trend(.hrvWeekly)?.points.first?.value)
        XCTAssertNil(report.trend(.hrvStatus))
    }
    func testCacheIsOwnerScopedAndRoundTripsOnlyHealthFields() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let first = GarminHRVStore(owner:"test-owner-one",root:root), second = GarminHRVStore(owner:"test-owner-two",root:root)
        let report = GarminHRVReport(summaries:[],nights:[:],refreshedAt:now)
        first.save(report)
        XCTAssertEqual(first.load(),report); XCTAssertNil(second.load())
        let filenames = try FileManager.default.contentsOfDirectory(atPath:root.path)
        XCTAssertFalse(filenames.joined().contains("test-owner"))
    }
}

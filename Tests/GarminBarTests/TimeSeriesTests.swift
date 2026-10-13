import XCTest
@testable import GarminBar

final class TimeSeriesTests: XCTestCase {
    private let day = Calendar.current.date(from: DateComponents(year: 2026, month: 10, day: 13))!
    private func data(_ value: Any) throws -> Data { try JSONSerialization.data(withJSONObject: value) }
    private func millis(_ seconds: Double) -> Double { day.addingTimeInterval(seconds).timeIntervalSince1970 * 1000 }

    func testBodyBatteryDescriptorsDoNotPlotStatusOrVersionAsBatteryLevel() throws {
        let raw: [String: Any] = ["calendarDate": GarminHealthMetrics.calendarDate(day),
            "bodyBatteryValueDescriptorsDTOList": [["bodyBatteryValueDescriptorIndex": 0, "bodyBatteryValueDescriptorKey": "timestamp"], ["bodyBatteryValueDescriptorIndex": 1, "bodyBatteryValueDescriptorKey": "bodyBatteryStatus"], ["bodyBatteryValueDescriptorIndex": 2, "bodyBatteryValueDescriptorKey": "bodyBatteryLevel"], ["bodyBatteryValueDescriptorIndex": 3, "bodyBatteryValueDescriptorKey": "bodyBatteryVersion"]],
            "bodyBatteryValuesArray": [[millis(60), 2, 84, 2], [millis(240), 9, NSNull(), 2], [millis(420), 1, 70, 2]]]
        let parsed = try GarminDailySeries.parse(data(raw), endpoint: .stress, day: day, now: day.addingTimeInterval(600))
        let series = try XCTUnwrap(parsed[.bodyBattery])
        XCTAssertEqual(series.values.compactMap(\.value), [84, 70])
        XCTAssertEqual(series.segments.count, 2)
        XCTAssertNil(series.points[1].value)
    }

    func testHeartRateRejectsWrongDayFutureAndMissingReadingsWithoutZeroFilling() throws {
        let raw: [String: Any] = ["calendarDate": GarminHealthMetrics.calendarDate(day), "heartRateValues": [[millis(0), NSNull()], [millis(60), 66], [millis(180), -1], [millis(300), 70], [millis(90000), 90], [millis(700), 80], [millis(360), true]]]
        let series = try XCTUnwrap(GarminDailySeries.parse(data(raw), endpoint: .heartRate, day: day, now: day.addingTimeInterval(600))[.heartRate])
        XCTAssertEqual(series.values.compactMap(\.value), [66, 70])
        XCTAssertEqual(series.points.count, 5)
        XCTAssertEqual(series.segments.count, 2)
        XCTAssertEqual(series.values.first?.timestamp, day.addingTimeInterval(60))
        var wrong = raw; wrong["calendarDate"] = "2026-10-12"
        XCTAssertTrue(try GarminDailySeries.parse(data(wrong), endpoint: .heartRate, day: day).isEmpty)
    }

    func testIntervalStepsAndFloorsPreserveIncrementsAndCursorSelectsContainingInterval() throws {
        let f = ISO8601DateFormatter()
        let rows: [[String: Any]] = [["startGMT": f.string(from: day), "endGMT": f.string(from: day.addingTimeInterval(900)), "steps": 86, "pushes": 0], ["startGMT": f.string(from: day.addingTimeInterval(900)), "endGMT": f.string(from: day.addingTimeInterval(1800)), "steps": 32, "pushes": 0]]
        let series = try XCTUnwrap(GarminDailySeries.parse(data(rows), endpoint: .steps, day: day, now: day.addingTimeInterval(3600))[.steps])
        XCTAssertEqual(series.total, 118)
        XCTAssertEqual(series.reading(at: day.addingTimeInterval(840))?.value, 86)
        XCTAssertEqual(series.reading(at: day.addingTimeInterval(1000))?.value, 32)
        XCTAssertNil(series.reading(at: day.addingTimeInterval(3000)))
        XCTAssertFalse(MetricKind.steps.acceptsLiveTimeline)
        XCTAssertFalse(MetricKind(rawValue: "floors")!.acceptsLiveTimeline)
        XCTAssertTrue(MetricKind.stress.acceptsLiveTimeline)
        let floorData = ["floorValuesArray": [[f.string(from: day), f.string(from: day.addingTimeInterval(900)), 2, 1]]] as [String: Any]
        let floors = try GarminDailySeries.parse(data(floorData), endpoint: .floors, day: day, now: day.addingTimeInterval(3600))
        XCTAssertEqual(floors[MetricKind(rawValue: "floors")!]?.total, 2)
        XCTAssertEqual(floors[MetricKind(rawValue: "daily.floorsDescended")!]?.total, 1)
    }

    func testHistoricalSolarUsesRequestedDayAndKeepsRealZeroAndChargingState() throws {
        let f = ISO8601DateFormatter()
        let rows: [[String: Any]] = [["readingTimestampGmt": f.string(from: day.addingTimeInterval(60)), "solarUtilization": 0, "charging": false], ["readingTimestampGmt": f.string(from: day.addingTimeInterval(120)), "solarUtilization": 49.17, "charging": true], ["readingTimestampGmt": f.string(from: day.addingTimeInterval(180)), "solarUtilization": 99, "interpolated": true]]
        let raw: [String: Any] = ["deviceSolarInput": ["solarDailyDataDTOs": [["localConnectDate": GarminHealthMetrics.calendarDate(day), "solarInputReadings": rows]]]]
        let series = try GarminHealthMetrics.solarTimeline(data(raw), day: day, now: day.addingTimeInterval(90000))
        XCTAssertEqual(series.points.count, 2)
        XCTAssertEqual(series.minimum, 0)
        XCTAssertEqual(series.maximum, 49.17)
        XCTAssertEqual(series.latest?.charging, true)
        XCTAssertTrue(try GarminHealthMetrics.solarTimeline(data(raw), day: day.addingTimeInterval(-86400)).points.isEmpty)
    }

    func testSpO2KeepsContinuousAndHourlyTypesSeparate() throws {
        let raw: [String: Any] = ["spO2HourlyAverages": [[millis(3600), 92], [millis(7200), 95]], "continuousReadingDTOList": [["spO2ContinuousValues": [[millis(3660), 93], [millis(3720), 94]]]]]
        let series = try XCTUnwrap(GarminDailySeries.parse(data(raw), endpoint: .spo2, day: day, now: day.addingTimeInterval(10800))[MetricKind(rawValue: "spo2")!])
        XCTAssertEqual(series.values.compactMap(\.value), [93, 94, 95])
        XCTAssertEqual(series.points.map(\.label), ["连续测量", "连续测量", "小时均值"])
        XCTAssertEqual(series.segments.count, 2)
    }

    func testLiveMinuteReadingSurvivesCloudRefreshWithoutBridgingLongGaps() throws {
        let live = MetricDaySeries(kind: .bodyBattery, day: day, points: [MetricSeriesPoint(timestamp: day.addingTimeInterval(180), value: 55, origin: .watch)], source: "Mac", refreshedAt: day)
        let cloud = MetricDaySeries(kind: .bodyBattery, day: day, points: [MetricSeriesPoint(timestamp: day.addingTimeInterval(180), value: 56), MetricSeriesPoint(timestamp: day.addingTimeInterval(3600), value: 51)], source: "佳明中国", refreshedAt: day)
        let merged = live.merging(cloud)
        XCTAssertEqual(merged.values.compactMap(\.value), [55, 51])
        XCTAssertEqual(merged.segments.count, 2)
        XCTAssertNil(merged.reading(at: day.addingTimeInterval(1800)))
    }

    func testPersistedChartsArePrivateAndScopedToAccountAndDate() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let first = MetricSeriesStore(accountGUID: "test-first", root: root)
        let second = MetricSeriesStore(accountGUID: "test-second", root: root)
        let series = MetricDaySeries(kind: .bodyBattery, day: day, points: [MetricSeriesPoint(timestamp: day.addingTimeInterval(180), value: 55)], source: "佳明中国", refreshedAt: day)
        first.save([.bodyBattery: series], day: day)
        XCTAssertEqual(first.load(day: day)[.bodyBattery], series)
        XCTAssertTrue(second.load(day: day).isEmpty)
        XCTAssertTrue(first.load(day: day.addingTimeInterval(86400)).isEmpty)
        let files = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)!
        for case let file as URL in files where file.pathExtension == "json" {
            XCTAssertEqual((try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        }
    }

    func testNearestLookupHandlesFullDayBoundariesAndMissingMinute() throws {
        let points = (0..<1440).map { index in MetricSeriesPoint(timestamp: day.addingTimeInterval(Double(index) * 60), value: index == 600 ? nil : Double(index % 100)) }
        let series = MetricDaySeries(kind: .solarIntensity, day: day, points: points, source: "test", refreshedAt: day)
        XCTAssertEqual(series.nearest(to: day.addingTimeInterval(-30))?.timestamp, day)
        XCTAssertEqual(series.nearest(to: day.addingTimeInterval(86400))?.timestamp, day.addingTimeInterval(1439 * 60))
        XCTAssertEqual(series.nearest(to: day.addingTimeInterval(600 * 60 + 20))?.timestamp, day.addingTimeInterval(600 * 60))
        XCTAssertNil(series.reading(at: day.addingTimeInterval(600 * 60 + 20))?.value)
        XCTAssertEqual(series.reading(at: day.addingTimeInterval(900 * 60 + 45))?.timestamp, day.addingTimeInterval(901 * 60))
    }
}

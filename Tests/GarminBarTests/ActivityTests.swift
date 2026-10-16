import Foundation
import XCTest
@testable import GarminBar

final class ActivityTests: XCTestCase {
    func testChartPresentationKeepsDurationDataAvailableToAIAndExports() throws {
        let summary = try GarminActivities.summary(activity())
        let series = ["sumDuration", "sumElapsedDuration", "sumMovingDuration", "directHeartRate"].map {
            GarminActivitySeries(key: $0, unit: $0 == "directHeartRate" ? "bpm" : "s", factor: nil, values: [10, 20])
        } + [GarminActivitySeries(key: "sumDistance", unit: "m", factor: nil, values: [0, 0])]
        let detail = GarminActivityDetail(summary: summary, series: series, fetchedAt: Date(), chartPointLimit: 1000, chartAvailable: true)
        XCTAssertEqual(ActivityMetricCatalog.visibleCharts(detail).map(\.key), ["directHeartRate"])
        var index = GarminActivityIndex(); index.activities = [summary]
        for key in ["sumDuration", "sumElapsedDuration", "sumMovingDuration"] {
            let result = try ActivityQueries.query("activity_series", arguments: ["id": summary.id, "metric": key], index: index, detail: { _ in detail }, formats: { _ in [] })
            XCTAssertEqual(result["values"] as? [Double], [10, 20])
        }
        let decoded = try JSONDecoder().decode(GarminActivityDetail.self, from: JSONEncoder().encode(detail))
        XCTAssertEqual(decoded.series, series)
        XCTAssertEqual(ActivityMetricCatalog.highlights(["duration": 600, "distance": 0, "calories": 200, "averageHR": 110, "maxHR": 150]).map(\.key), ["duration", "calories", "averageHR", "maxHR"])
    }
    func testExpandedMetricsKeepSIUnitsAndNullChartGaps() throws {
        let summary: [String: Any] = ["activityId": 1001, "summaryDTO": ["averageTemperature": 20, "waterEstimated": 500, "avgElevation": 120, "trainingEffect": 2.1]]
        let chart: [String: Any] = ["activityId": 1001, "metricDescriptors": [
            ["key": "directTimestamp", "metricsIndex": 0, "unit": ["key": "gmt", "factor": 0]],
            ["key": "directSpeed", "metricsIndex": 1, "unit": ["key": "mps", "factor": 0.1]],
            ["key": "directAirTemperature", "metricsIndex": 2, "unit": ["key": "celcius", "factor": 1]]],
            "activityDetailMetrics": [["metrics": [1000, 2.5, 20]], ["metrics": [2000, NSNull(), NSNull()]], ["metrics": [3000, 3, 22]]]]
        let detail = try GarminActivities.detail(summary: data(summary), chart: data(chart), expectedID: "1001")
        XCTAssertEqual(detail.summary.statistics["averageTemperature"], 20)
        XCTAssertEqual(detail.summary.statistics["waterEstimated"], 500)
        XCTAssertEqual(detail.series.first { $0.key == "directAirTemperature" }?.values, [20, nil, 22])
        let points = ActivityChartPoint.points(detail, metric: "directSpeed")
        XCTAssertEqual(points.map(\.value), [2.5, 3])
        XCTAssertEqual(points.map(\.segment), [0, 1])
        XCTAssertEqual(points.first?.time.timeIntervalSince1970, 1)
        XCTAssertEqual(ActivityMetricCatalog.duration(3661), "1:01:01")
        XCTAssertEqual(ActivityMetricCatalog.duration(.infinity), "—")
        XCTAssertEqual(ActivityMetricCatalog.statistics.first { $0.key == "averageSpeed" }?.formatted(2.5), "9.0 km/h")
    }
    func testSupplementalSectionsValidateIdentityAndDoNotExposeCoordinates() throws {
        let zones = try GarminActivities.zones(data([["zoneNumber": 1, "secsInZone": 120, "zoneLowBoundary": 90]]))
        XCTAssertEqual(zones.first?.seconds, 120)
        XCTAssertThrowsError(try GarminActivities.zones(data([["zoneNumber": 1, "secsInZone": -1]])))
        XCTAssertThrowsError(try GarminActivities.zones(data([["zoneNumber": true, "secsInZone": 1]])))
        let lap: [String: Any] = ["lapIndex": 1, "duration": 300, "distance": 500, "startLatitude": 12.3, "ownerId": "private-owner"]
        let laps = try GarminActivities.laps(data(["activityId": 1001, "lapDTOs": [lap]]), expectedID: "1001")
        XCTAssertEqual(laps.first?.statistics["duration"], 300)
        let encoded = String(decoding: try JSONEncoder().encode(laps), as: UTF8.self)
        XCTAssertFalse(encoded.contains("Latitude")); XCTAssertFalse(encoded.contains("ownerId"))
        XCTAssertThrowsError(try GarminActivities.laps(data(["activityId": 1002, "lapDTOs": [lap]]), expectedID: "1001"))
        XCTAssertThrowsError(try GarminActivities.laps(data(["activityId": 1001, "lapDTOs": [lap, lap]]), expectedID: "1001"))
    }
    func testOldDetailCacheRemainsReadableAndMCPPartitionsLaps() throws {
        let summary = try GarminActivities.summary(activity())
        var detail = GarminActivityDetail(summary: summary, series: [], fetchedAt: Date(), chartPointLimit: 1000, chartAvailable: false)
        let old = try JSONEncoder().encode(detail)
        XCTAssertNil(try JSONDecoder().decode(GarminActivityDetail.self, from: old).laps)
        detail.laps = (1...105).map { .init(index: $0, statistics: ["duration": 60]) }
        detail.heartRateZones = [.init(number: 1, seconds: 120, lowerBPM: 90)]
        var index = GarminActivityIndex(); index.activities = [summary]
        let result = try ActivityQueries.query("activity", arguments: ["id": "1001"], index: index, detail: { _ in detail }, formats: { _ in [] })
        XCTAssertEqual((result["laps"] as? [[String: Any]])?.count, 100)
        XCTAssertEqual(result["nextLapOffset"] as? Int, 100)
        XCTAssertEqual(result["heartRateZonesCached"] as? Bool, true)
        let next = try ActivityQueries.query("activity", arguments: ["id": "1001", "lapOffset": 100], index: index, detail: { _ in detail }, formats: { _ in [] })
        XCTAssertEqual((next["laps"] as? [[String: Any]])?.count, 5)
        XCTAssertTrue(next["nextLapOffset"] is NSNull)
        XCTAssertThrowsError(try ActivityQueries.query("activity", arguments: ["id": "1001", "lapLimit": 0], index: index, detail: { _ in detail }, formats: { _ in [] }))
    }
    private func data(_ object: Any) throws -> Data { try JSONSerialization.data(withJSONObject: object) }
    private func activity(_ id: Int = 1001) -> [String: Any] {
        ["activityId": id, "activityName": "Synthetic run", "activityType": ["typeKey": "running"],
         "startTimeLocal": "2026-01-02 10:00:00", "startTimeGMT": "2026-01-02 02:00:00", "duration": 600,
         "averageHR": NSNull(), "distance": 1200, "maxHR": true, "ownerId": "private-owner", "deviceId": "private-device",
         "startLatitude": 12.34, "startLongitude": 56.78]
    }
    func testSummaryProjectionDropsIdentityAndCoordinatesPreservesMissingValues() throws {
        let result = try GarminActivities.list(data([activity()]))
        XCTAssertEqual(result.count, 1); XCTAssertEqual(result[0].statistics["duration"], 600)
        XCTAssertNil(result[0].statistics["averageHR"]); XCTAssertNil(result[0].statistics["maxHR"])
        let encoded = String(decoding: try JSONEncoder().encode(result), as: UTF8.self)
        for forbidden in ["private-owner", "private-device", "Latitude", "Longitude", "ownerId", "deviceId"] { XCTAssertFalse(encoded.contains(forbidden)) }
        XCTAssertThrowsError(try GarminActivities.summary(["activityId": true]))
        XCTAssertThrowsError(try GarminActivities.list(data([activity(), activity()])))
        XCTAssertThrowsError(try GarminActivities.list(data(["activityList": [activity()]])))
        XCTAssertThrowsError(try GarminActivities.list(Data(repeating: 32, count: GarminActivities.maximumJSONBytes + 1)))
    }
    func testDescriptorOrderNullsAndReducedSamplingArePreserved() throws {
        let summary: [String: Any] = ["activityId": 1001, "summaryDTO": ["trainingEffect": 2.4, "totalExerciseReps": 8]]
        let chart: [String: Any] = ["activityId": 1001, "metricDescriptors": [
            ["key": "directHeartRate", "metricsIndex": 2, "unit": ["key": "bpm", "factor": 1]],
            ["key": "directTimestamp", "metricsIndex": 0, "unit": ["key": "gmt", "factor": 0]],
            ["key": "directLatitude", "metricsIndex": 1]],
            "activityDetailMetrics": [["metrics": [1000, 25, 110]], ["metrics": [2000, 25, NSNull()]], ["metrics": [3000, 25, true]]]]
        let parsed = try GarminActivities.detail(summary: data(summary), chart: data(chart), expectedID: "1001")
        XCTAssertEqual(parsed.summary.statistics["aerobicTrainingEffect"], 2.4)
        XCTAssertEqual(parsed.summary.statistics["totalReps"], 8)
        XCTAssertEqual(parsed.series.map(\.key), ["directHeartRate", "directTimestamp"])
        XCTAssertEqual(parsed.series[0].values, [110, nil, nil])
        XCTAssertEqual(parsed.chartPointLimit, 1000); XCTAssertTrue(parsed.chartAvailable)
        XCTAssertThrowsError(try GarminActivities.detail(summary: data(summary), chart: data(chart), expectedID: "1002"))
    }
    func testCloudURLsAndCachePathsRejectTraversalAndNonDecimalIDs() throws {
        for id in ["", "0", "01", "../auth/session", "１２３", "1?x=y", "9223372036854775808"] { XCTAssertFalse(GarminActivities.validID(id)) }
        let china = try GarminActivities.listURL(region: .china, offset: 50)
        XCTAssertEqual(china.host, "connectapi.garmin.cn")
        XCTAssertTrue(china.query?.contains("start=50") == true)
        XCTAssertEqual(try GarminActivities.listURL(region: .global, offset: 0).host, "connectapi.garmin.com")
        XCTAssertThrowsError(try GarminActivities.listURL(region: .china, offset: -1))
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let a = GarminActivityStore(root: root, scope: "china:fixture-a"), b = GarminActivityStore(root: root, scope: "global:fixture-a")
        XCTAssertNotEqual(a.directory, b.directory)
        XCTAssertThrowsError(try a.file("../token", extension: "json"))
        XCTAssertThrowsError(try a.file("1001", extension: "../token"))
    }
    func testExportsRejectEmptyGPSHTMLAndEntityExpansion() throws {
        try GarminActivities.validateFile(Data("<gpx><trk><trkseg><trkpt lat=\"0\" lon=\"0\"/></trkseg></trk></gpx>".utf8), format: .gpx)
        XCTAssertThrowsError(try GarminActivities.validateFile(Data("<gpx><metadata/></gpx>".utf8), format: .gpx))
        XCTAssertThrowsError(try GarminActivities.validateFile(Data("<html>Login</html>".utf8), format: .tcx))
        XCTAssertThrowsError(try GarminActivities.validateFile(Data("<!DOCTYPE gpx [<!ENTITY x 'expand'>]><gpx>&x;</gpx>".utf8), format: .gpx))
        try GarminActivities.validateFile(Data("<TrainingCenterDatabase/>".utf8), format: .tcx)
        XCTAssertThrowsError(try GarminActivities.validateFile(Data("not zip".utf8), format: .original))
    }
    func testAccountCachesRoundTripWithPrivatePermissions() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let a = GarminActivityStore(root: root, scope: "china:fixture-a"), b = GarminActivityStore(root: root, scope: "china:fixture-b")
        var index = GarminActivityIndex(); index.activities = try GarminActivities.list(data([activity()]))
        try a.saveIndex(index)
        XCTAssertEqual(a.loadIndex().activities.count, 1); XCTAssertEqual(b.loadIndex().activities.count, 0)
        let mode = try FileManager.default.attributesOfItem(atPath: a.directory.appendingPathComponent("index.json").path)[.posixPermissions] as? NSNumber
        XCTAssertEqual(mode?.intValue, 0o600)
    }
    func testMCPPaginationFiltersAndMissingDetailsAreExplicit() throws {
        var index = GarminActivityIndex(); index.activities = try GarminActivities.list(data([activity(1002), activity()]))
        let page = try ActivityQueries.query("activities", arguments: ["limit": 1, "startDate": "2026-01-01"], index: index, detail: { _ in nil }, formats: { _ in [] })
        XCTAssertEqual((page["activities"] as? [[String: Any]])?.count, 1)
        XCTAssertEqual(page["nextOffset"] as? Int, 1); XCTAssertEqual(page["historyEndReached"] as? Bool, false)
        let result = try ActivityQueries.query("activity", arguments: ["id": "1001"], index: index, detail: { _ in nil }, formats: { _ in [] })
        XCTAssertEqual(result["cached"] as? Bool, true); XCTAssertEqual(result["detailCached"] as? Bool, false)
        let invalid: [[String: Any]] = [["limit": true], ["limit": 101], ["startDate": "2026-02-30"], ["refresh": true], ["startDate": "2026-02-01", "endDate": "2026-01-01"]]
        for arguments in invalid {
            XCTAssertThrowsError(try ActivityQueries.query("activities", arguments: arguments, index: index, detail: { _ in nil }, formats: { _ in [] }))
        }
        XCTAssertThrowsError(try ActivityQueries.query("activity_series", arguments: ["id": "1001", "metric": "directLatitude"], index: index, detail: { _ in nil }, formats: { _ in [] }))
    }
}

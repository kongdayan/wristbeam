import Foundation
import XCTest
@testable import GarminBar

final class ActivityTests: XCTestCase {
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

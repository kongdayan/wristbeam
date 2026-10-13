import XCTest
@testable import GarminBar

final class WidgetTests: XCTestCase {
    func testSnapshotRetainsTimeAndMissingSegmentsWithoutCredentials() throws {
        let now = Date()
        let reading = PulseWidgetReading(id: "solarIntensity", title: "太阳能强度", symbol: "sun.max.fill", value: "49", unit: "%", source: "已同步", updatedAt: now, stale: false, category: "solar", segments: [[PulseWidgetPoint(seconds: 60, value: 12)], [PulseWidgetPoint(seconds: 600, value: 49)]], lowerBound: 0, upperBound: 100)
        let snapshot = PulseWidgetSnapshot(generatedAt: now, day: Calendar.current.startOfDay(for: now), regionTitle: "佳明中国", watchConnected: false, readings: [reading])
        let bytes = try JSONEncoder().encode(snapshot)
        let decoded = try PulseWidgetSnapshot.decode(bytes)
        XCTAssertEqual(decoded, snapshot)
        XCTAssertEqual(decoded.readings[0].segments.count, 2)
        let text = String(data: bytes, encoding: .utf8)!
        for privateKey in ["accessToken", "refreshToken", "password", "accountGUID", "deviceID"] { XCTAssertFalse(text.contains(privateKey)) }
        var corrupt = snapshot; corrupt.schemaVersion = 999
        XCTAssertThrowsError(try PulseWidgetSnapshot.decode(JSONEncoder().encode(corrupt)))
    }
    func testMetricDeepLinkRejectsAuthenticationPayloadAndFutureDates() {
        let day = Calendar.current.startOfDay(for: Date())
        let destination = PulseWidgetLink.destination(PulseWidgetLink.url(metricID: "daily.maxHeartRate", day: day))
        XCTAssertEqual(destination?.metricID, "daily.maxHeartRate")
        XCTAssertEqual(destination?.day, day)
        for value in ["garminpulse://metric/heartRate?ticket=ST-test", "garminpulse://metric/heartRate?date=2099-01-01", "garminpulse://metric/heartRate?date=2026-99-40", "garminpulse://login/heartRate", "https://metric/heartRate", "garminpulse://metric/heartRate/extra", "garminpulse://metric/heartRate#access_token=test"] {
            XCTAssertNil(PulseWidgetLink.destination(URL(string: value)!))
        }
    }
}

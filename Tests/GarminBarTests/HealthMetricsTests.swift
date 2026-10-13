import XCTest
@testable import GarminBar

final class HealthMetricsTests: XCTestCase {
    func testDailyMetricsUseKnownFieldsAndDoNotTreatIdentityOrMissingDataAsMeasurements() throws {
        let now = Date()
        let object: [String: Any] = ["calendarDate": GarminHealthMetrics.calendarDate(now), "bodyBatteryMostRecentValue": 56,
                                    "totalSteps": 5180, "totalDistanceMeters": 4217, "restingHeartRate": 53,
                                    "bodyBatteryChargedValue": 0, "latestSpo2": -1, "totalKilocalories": true,
                                    "moderateIntensityMinutes": 10, "vigorousIntensityMinutes": 5, "userProfileId": 123]
        let samples = try GarminHealthMetrics.daily(JSONSerialization.data(withJSONObject: object), now: now)
        XCTAssertEqual(samples.first { $0.kind == .bodyBattery }?.value, 56)
        let distance = try XCTUnwrap(samples.first { $0.kind.rawValue == "daily.totalDistanceMeters" }?.value)
        XCTAssertTrue(abs(distance - 4.217) < 0.000001)
        XCTAssertEqual(samples.first { $0.kind.rawValue == "intensityMinutes" }?.value, 20)
        XCTAssertTrue(samples.allSatisfy { $0.origin == .cloud })
        XCTAssertFalse(samples.contains { ["spo2", "calories", "daily.userProfileId"].contains($0.kind.rawValue) })
        XCTAssertEqual(samples.first { $0.kind.rawValue == "daily.bodyBatteryChargedValue" }?.value, 0)
    }

    func testSolarMinutesExcludeInterpolationAndGapsAndPreserveRealReadingTime() throws {
        let now = Calendar.current.date(from: DateComponents(year: 2026, month: 10, day: 13, hour: 14))!
        let start = now.addingTimeInterval(-3600)
        let formatter = ISO8601DateFormatter()
        func point(_ offset: TimeInterval, _ value: Double, _ charging: Bool, interpolated: Bool = false) -> [String: Any] {
            ["readingTimestampGmt": formatter.string(from: start.addingTimeInterval(offset)), "solarUtilization": value,
             "charging": charging, "interpolated": interpolated]
        }
        let points = [point(0,40,true), point(10,50,true), point(60,10,true), point(120,99,true,interpolated:true), point(1800,30,false), point(1900,-1,true), point(7200,100,true)]
        let data = try JSONSerialization.data(withJSONObject: ["deviceSolarInput": ["solarDailyDataDTOs": [["localConnectDate": GarminHealthMetrics.calendarDate(now), "solarInputReadings": points]]]])
        let samples = try GarminHealthMetrics.solar(data, threshold: 20, now: now)
        XCTAssertEqual(samples.first { $0.kind == .solarIntensity }?.value, 30)
        XCTAssertEqual(samples.first { $0.kind == .solarIntensity }?.timestamp, start.addingTimeInterval(1800))
        XCTAssertEqual(samples.first { $0.kind == .sunlightMinutes }?.value, 2)
        XCTAssertEqual(samples.first { $0.kind == .solarChargingMinutes }?.value, 2)
        XCTAssertEqual(samples.first { $0.kind == .sunlightMinutes }?.origin, .estimated)
    }

    func testNoTodaySolarSamplesRemainUnavailableRatherThanZero() throws {
        XCTAssertTrue(try GarminHealthMetrics.solar(Data("{}".utf8)).isEmpty)
        XCTAssertTrue(try GarminHealthMetrics.solar(Data("{\"deviceSolarInput\":{\"solarDailyDataDTOs\":[]}}".utf8)).isEmpty)
        XCTAssertTrue(try GarminHealthMetrics.daily(Data("{\"calendarDate\":\"2000-01-01\",\"totalSteps\":42}".utf8)).isEmpty)
    }
}

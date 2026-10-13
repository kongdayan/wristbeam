import XCTest
@testable import GarminBar

final class MetricsTests: XCTestCase {
    func testBodyBatteryRealtimeUsesItsOwnServiceAndRejectsUnavailableBytes() throws {
        let (kind, value) = try MetricPacketParser.realtime(service: 20, data: Data([56]))
        XCTAssertEqual(kind, .bodyBattery); XCTAssertEqual(value, 56)
        XCTAssertEqual(try MetricPacketParser.realtime(service: 20, data: Data([0])).1, 0)
        XCTAssertThrowsError(try MetricPacketParser.realtime(service: 20, data: Data([255])))
        XCTAssertThrowsError(try MetricPacketParser.realtime(service: 20, data: Data([101])))
        XCTAssertThrowsError(try MetricPacketParser.realtime(service: 20, data: Data()))
        XCTAssertEqual(try JSONDecoder().decode(MetricKind.self, from: Data("\"heartRate\"".utf8)), .heartRate)
        XCTAssertEqual(String(data: try JSONEncoder().encode(kind), encoding: .utf8), "\"bodyBattery\"")
    }

    func testExtendedRealtimeChannelsKeepTheirUnitsAndSentinels() throws {
        XCTAssertEqual(try MetricPacketParser.realtime(service: 8, data: Data([0x5a,0x06,0,0])).1, 1626)
        XCTAssertEqual(try MetricPacketParser.realtime(service: 9, data: Data([2,0,1,0,10,0])).1, 2)
        XCTAssertEqual(try MetricPacketParser.realtime(service: 10, data: Data([25,0] + Array(repeating: UInt8(0), count: 12))).1, 25)
        XCTAssertEqual(try MetricPacketParser.realtime(service: 21, data: Data([14])).1, 14)
        XCTAssertEqual(try MetricPacketParser.realtime(service: 19, data: Data([97,0,0,0,0])).1, 97)
        XCTAssertThrowsError(try MetricPacketParser.realtime(service: 12, data: Data([255,255])))
        XCTAssertThrowsError(try MetricPacketParser.realtime(service: 19, data: Data([255,0,0,0,0])))
        XCTAssertThrowsError(try MetricPacketParser.realtime(service: 25, data: Data([101,0,0,0])))
        XCTAssertEqual(Set(MetricKind.allCases.map(\.rawValue)).count, MetricKind.allCases.count)
    }

    func testHeartRateFlagSelectsWidthAndIgnoresOptionalRR() throws {
        XCTAssertEqual(try MetricPacketParser.standardHeartRate(Data([0, 72, 0xA1, 1])), 72)
        XCTAssertEqual(try MetricPacketParser.standardHeartRate(Data([1, 0x04, 0x01])), 260)
        XCTAssertThrowsError(try MetricPacketParser.standardHeartRate(Data([1, 72])))
    }
    func testGarminSentinelDoesNotBecomeRealReading() throws {
        XCTAssertEqual(try MetricPacketParser.garminHeartRate(Data([3, 66, 55, 44, 88])), 66)
        XCTAssertThrowsError(try MetricPacketParser.garminHeartRate(Data([0, 255, 255, 255, 255])))
        XCTAssertThrowsError(try MetricPacketParser.garminStress(Data([255, 255, 0])))
        XCTAssertThrowsError(try MetricPacketParser.garminStress(Data([0x64])))
    }
    func testStepsUseFullLittleEndianCounter() throws {
        XCTAssertEqual(try MetricPacketParser.garminSteps(Data([0x39, 0x30, 0, 0])), 12345)
        XCTAssertThrowsError(try MetricPacketParser.garminSteps(Data([255, 255, 255, 255])))
        XCTAssertEqual(try MetricPacketParser.garminStress(Data([47, 0, 0])), 47)
    }
    func testMultiLinkFormatsCannotBeConfusedWithLegacyStress() throws {
        XCTAssertEqual(try MetricPacketParser.multiLinkHeartRate(Data([3, 71, 54])), 71)
        XCTAssertEqual(try MetricPacketParser.multiLinkStress(Data([24])), 24)
        XCTAssertEqual(try MetricPacketParser.multiLinkStress(Data([24, 0, 0])), 24)
        XCTAssertThrowsError(try MetricPacketParser.multiLinkStress(Data([24, 0])))
        XCTAssertThrowsError(try MetricPacketParser.multiLinkStress(Data([255])))
    }
}

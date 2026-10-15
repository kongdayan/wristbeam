import Foundation
import XCTest
@testable import GarminBar

final class WeatherProtocolTests: XCTestCase {
    private let date = Date(timeIntervalSince1970: 631_066_600)

    func testRequestUsesSignedSemicirclesAndForecastAcknowledgement() throws {
        // FIT format, +45 latitude, -90 longitude, 24 hours. Coordinates are little endian.
        let request = try GFDIWeatherRequest(payload: Data([0, 0, 0, 0, 0x20, 0, 0, 0, 0xc0, 24]))
        XCTAssertEqual(request.latitude, 45)
        XCTAssertEqual(request.longitude, -90)
        XCTAssertEqual(request.forecastHours, 24)
        XCTAssertEqual(request.acknowledgementPayload, Data([128, 2, 44, 1]))
        let unknown = try GFDIWeatherRequest(payload: Data([0, 255, 255, 255, 127, 255, 255, 255, 127, 0]))
        XCTAssertNil(unknown.latitude)
        XCTAssertNil(unknown.longitude)
        XCTAssertEqual(unknown.acknowledgementPayload, Data([128, 1, 44, 1]))
        for size in [0, 9, 11] {
            XCTAssertThrowsError(try GFDIWeatherRequest(payload: Data(repeating: 0, count: size)))
        }
        XCTAssertThrowsError(try GFDIWeatherRequest(payload: Data([1] + Array(repeating: 0, count: 9)))) { error in
            XCTAssertEqual(error as? GFDIWeatherError, .unsupportedFormat(1))
        }
    }

    func testCurrentConditionsDefinitionAndIndependentByteFixture() throws {
        var current = WatchWeatherSnapshot.Conditions(timestamp: date)
        current.temperatureC = 25.6
        current.feelsLikeC = -2
        current.condition = 3
        current.windSpeedMPS = 2.5
        current.windDirectionDegrees = 270
        current.relativeHumidity = 81
        current.highC = 30
        current.lowC = 20
        current.precipitationProbability = 60
        let snapshot = WatchWeatherSnapshot(location: .init(name: "Test City", latitude: 90, longitude: -90), fetchedAt: date, current: current)
        let frames = GFDIWeather.frames(snapshot: snapshot, forecastHours: 0)
        XCTAssertEqual(frames.map(\.number), [5011, 5012])
        XCTAssertEqual(Array(frames[0].payload.prefix(6)), [0x46, 0, 1, 0, 128, 15])
        // Header 6; report0; timestamp1000; observed1000; temp26; low20; high30;
        // rain3; direction270; precip60; wind2500; feels-2; humidity81; +90/-90 semicircles.
        let expected: [UInt8] = [6, 0, 0, 0, 3, 232, 0, 0, 3, 232, 26, 20, 30, 3,
                                 1, 14, 60, 9, 196, 254, 81, 64, 0, 0, 0, 192, 0, 0, 0]
            + Array("Test City".utf8) + [0]
        XCTAssertEqual(frames[1].payload, Data(expected))
        for frame in frames { XCTAssertEqual(try GFDIMessage.decode(frame.packet()), frame) }
        let values = try records(frames)
        XCTAssertEqual(values[0].global, 128)
        XCTAssertEqual(values[0].fields[4], [9, 196])
        XCTAssertEqual(values[0].fields[253], [0, 0, 3, 232])
    }

    func testMissingAndOutOfRangeValuesUseFITInvalidInsteadOfInventedWeather() throws {
        var current = WatchWeatherSnapshot.Conditions(timestamp: .distantPast)
        current.temperatureC = .nan
        current.feelsLikeC = 127
        current.windSpeedMPS = 1000
        current.windDirectionDegrees = -1
        current.condition = 250
        current.relativeHumidity = 101
        let snapshot = WatchWeatherSnapshot(location: .init(name: "", latitude: .infinity, longitude: 181), fetchedAt: date, current: current)
        let parsed = try records(GFDIWeather.frames(snapshot: snapshot, forecastHours: 0))[0].fields
        XCTAssertEqual(parsed[1], [127])
        XCTAssertEqual(parsed[6], [127])
        XCTAssertEqual(parsed[2], [255])
        XCTAssertEqual(parsed[3], [255, 255])
        XCTAssertEqual(parsed[4], [255, 255])
        XCTAssertEqual(parsed[5], [255])
        XCTAssertEqual(parsed[7], [255])
        XCTAssertEqual(parsed[9], [255, 255, 255, 255])
        XCTAssertEqual(parsed[10], [127, 255, 255, 255])
        XCTAssertEqual(parsed[11], [127, 255, 255, 255])
        XCTAssertEqual(parsed[8], [0])
    }

    func testForecastLimitsDailyWeekdayUVAndAlertRecords() throws {
        var hour = WatchWeatherSnapshot.Conditions(timestamp: date)
        hour.uvIndex = 2.5
        hour.dewPointC = 10
        hour.airQuality = 4
        var day = WatchWeatherSnapshot.Conditions(timestamp: date)
        day.dayOfWeek = 0
        day.highC = 28
        day.lowC = 16
        var alert = WatchWeatherSnapshot.Alert(identifier: "synthetic-alert")
        alert.issuedAt = date
        alert.expiresAt = date.addingTimeInterval(3600)
        alert.severity = 1
        alert.type = 13
        let snapshot = WatchWeatherSnapshot(location: .init(name: "Fixture", latitude: 0, longitude: 0), fetchedAt: date,
                                            current: .init(timestamp: date), hourly: Array(repeating: hour, count: 60),
                                            daily: Array(repeating: day, count: 7), alerts: [alert])
        let parsed = try records(GFDIWeather.frames(snapshot: snapshot, forecastHours: 2))
        XCTAssertEqual(parsed.count, 9) // current + 2 hours + 5 days + alert
        XCTAssertEqual(parsed[1].fields[0], [1])
        XCTAssertEqual(parsed[1].fields[16], [64, 32, 0, 0]) // float32 2.5, big endian
        XCTAssertEqual(parsed[1].fields[17], [4])
        XCTAssertEqual(parsed[3].fields[0], [2])
        XCTAssertEqual(parsed[3].fields[12], [0])
        XCTAssertEqual(parsed[8].global, 129)
        XCTAssertEqual(parsed[8].fields[1], [0, 0, 3, 232])
        XCTAssertEqual(parsed[8].fields[2], [0, 0, 17, 248]) // FIT4600
        XCTAssertEqual(parsed[8].fields[3], [1])
        XCTAssertEqual(parsed[8].fields[4], [13])
        XCTAssertEqual(try records(GFDIWeather.frames(snapshot: snapshot, forecastHours: 255)).count, 55)
        XCTAssertEqual(try records(GFDIWeather.frames(snapshot: snapshot, forecastHours: -1)).count, 7)
        XCTAssertEqual(try JSONDecoder().decode(WatchWeatherSnapshot.self, from: JSONEncoder().encode(snapshot)), snapshot)
    }

    func testStringsRemainValidUTF8AndUnavailableAlertsDoNotCreateReports() throws {
        let longName = String(repeating: "测试🌤", count: 100)
        var snapshot = WatchWeatherSnapshot(location: .init(name: longName, latitude: 0, longitude: 180), fetchedAt: date, current: .init(timestamp: date))
        let values = try records(GFDIWeather.frames(snapshot: snapshot, forecastHours: 0))
        let location = try XCTUnwrap(values.first?.fields[8])
        XCTAssertTrue(location.count <= 64)
        XCTAssertEqual(location.last, 0)
        XCTAssertNotNil(String(bytes: location.dropLast(), encoding: .utf8))
        XCTAssertEqual(values.first?.fields[11], [128, 0, 0, 0])
        XCTAssertEqual(values.count, 1)
        snapshot.alerts = []
        XCTAssertEqual(try records(GFDIWeather.frames(snapshot: snapshot, forecastHours: 0)).count, 1)
        snapshot.location.longitude = 179.99999999999
        XCTAssertEqual(try records(GFDIWeather.frames(snapshot: snapshot, forecastHours: 0))[0].fields[11], [127, 255, 255, 254])
    }

    /// A deliberately separate minimal FIT record reader verifies definition lengths and payload framing.
    private func records(_ frames: [GFDIMessage]) throws -> [(global: Int, fields: [UInt8: [UInt8]])] {
        var definitions: [UInt8: (global: Int, fields: [(UInt8, Int)])] = [:]
        var result: [(global: Int, fields: [UInt8: [UInt8]])] = []
        for frame in frames {
            let bytes = Array(frame.payload)
            guard let first = bytes.first else { throw GFDIProtocolError.truncated }
            if frame.number == 5011 {
                guard bytes.count >= 6, first & 0x40 != 0, bytes[2] == 1, bytes.count == 6 + Int(bytes[5]) * 3 else {
                    throw GFDIProtocolError.invalidLength
                }
                let fields = stride(from: 6, to: bytes.count, by: 3).map { (bytes[$0], Int(bytes[$0 + 1])) }
                definitions[first & 15] = (Int(bytes[3]) * 256 + Int(bytes[4]), fields)
            } else {
                guard frame.number == 5012, let definition = definitions[first], bytes.count == 1 + definition.fields.reduce(0, { $0 + $1.1 }) else {
                    throw GFDIProtocolError.invalidLength
                }
                var cursor = 1
                var values: [UInt8: [UInt8]] = [:]
                for (number, length) in definition.fields {
                    values[number] = Array(bytes[cursor..<(cursor + length)])
                    cursor += length
                }
                result.append((definition.global, values))
            }
        }
        return result
    }
}

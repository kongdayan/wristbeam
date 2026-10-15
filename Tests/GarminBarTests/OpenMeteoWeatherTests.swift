import Foundation
import XCTest
@testable import GarminBar

private final class OpenMeteoHTTP: URLProtocol {
    private static let lock = NSLock()
    private static var hold = false
    private static var code = 200
    private static var seen: [URLRequest] = []
    static func reset(stall: Bool = false, status: Int = 200) { lock.lock(); defer { lock.unlock() }; hold = stall; code = status; seen = [] }
    static var requests: [URLRequest] { lock.lock(); defer { lock.unlock() }; return seen }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.lock.lock(); Self.seen.append(request); let stall = Self.hold, status = Self.code; Self.lock.unlock()
        if stall { return }
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil,
            headerFields: ["Content-Type": "application/json"])!, cacheStoragePolicy: .notAllowed)
        let fixture = OpenMeteoWeatherTests.fixture(now: Date())
        client?.urlProtocol(self, didLoad: try! JSONSerialization.data(withJSONObject: fixture))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

final class OpenMeteoWeatherTests: XCTestCase {
    static func fixture(now: Date) -> [String: Any] {
        let epoch = now.timeIntervalSince1970
        let midnight = floor((epoch + 28800) / 86400) * 86400 - 28800
        let current: [String: Any] = ["time": epoch, "temperature_2m": 20, "apparent_temperature": 19,
            "relative_humidity_2m": 65, "weather_code": 63, "wind_speed_10m": 3.5, "wind_direction_10m": 180]
        let units = ["time": "unixtime", "temperature_2m": "°C", "apparent_temperature": "°C", "wind_speed_10m": "m/s", "dew_point_2m": "°C"]
        return ["current": current, "current_units": units, "utc_offset_seconds": 28800, "timezone": "Asia/Shanghai",
            "hourly_units": units,
            "hourly": ["time": [epoch - 3600, epoch + 3600, epoch + 7200], "temperature_2m": [19, 21, 22],
                "weather_code": [0, 2, 95], "wind_speed_10m": [2, 3, 4], "uv_index": [0, 2, 3]],
            "daily_units": ["time": "unixtime", "temperature_2m_max": "°C", "temperature_2m_min": "°C"],
            "daily": ["time": [midnight, midnight + 86400], "temperature_2m_max": [25, 26],
                "temperature_2m_min": [15, 16], "weather_code": [2, 45], "precipitation_probability_max": [50, 70]]]
    }
    private func data(_ raw: Any) throws -> Data { try JSONSerialization.data(withJSONObject: raw) }

    func testPublicWeatherRequestIsFixedHostExplicitUnitsNoCredential() throws {
        let url = try OpenMeteoWeather.url(latitude: 31, longitude: 121)
        XCTAssertEqual(url.scheme, "https"); XCTAssertEqual(url.host, "api.open-meteo.com")
        XCTAssertEqual(url.path, "/v1/forecast")
        let query = Dictionary(uniqueKeysWithValues: URLComponents(url: url, resolvingAgainstBaseURL: false)!.queryItems!.map { ($0.name, $0.value!) })
        XCTAssertEqual(query["timeformat"], "unixtime"); XCTAssertEqual(query["timezone"], "auto")
        XCTAssertEqual(query["wind_speed_unit"], "ms"); XCTAssertEqual(query["temperature_unit"], "celsius")
        XCTAssertEqual(query["forecast_days"], "5"); XCTAssertNil(query["apikey"])
        XCTAssertThrowsError(try OpenMeteoWeather.url(latitude: .nan, longitude: 0))
        XCTAssertThrowsError(try OpenMeteoWeather.url(latitude: 0, longitude: 181))
    }

    func testForecastUsesCityDateFutureHoursAndNeverFabricatesAlerts() throws {
        // Monday in Shanghai, still Sunday in UTC and on many Macs.
        let now = Date(timeIntervalSince1970: 1_704_040_200)
        let value = try OpenMeteoWeather.parse(data(Self.fixture(now: now)), latitude: 31, longitude: 121, city: "Fixture", now: now)
        XCTAssertEqual(value.current.temperatureC, 20); XCTAssertEqual(value.current.windSpeedMPS, 3.5)
        XCTAssertEqual(value.current.condition, 3); XCTAssertEqual(value.current.highC, 25)
        XCTAssertEqual(value.hourly.count, 2); XCTAssertEqual(value.hourly.map(\.condition), [1, 6])
        XCTAssertTrue(value.hourly.allSatisfy { $0.timestamp > now })
        XCTAssertEqual(value.daily.map(\.dayOfWeek), [1, 2]); XCTAssertEqual(value.daily[1].condition, 8)
        XCTAssertNil(value.alerts); XCTAssertEqual(value.unavailableSections, ["alerts"])
        XCTAssertNil(value.current.airQuality)
    }

    func testInvalidUnitsStaleDatesAndOversizeAreRejected() throws {
        let now = Date()
        var raw = Self.fixture(now: now)
        raw["current_units"] = ["time": "unixtime", "temperature_2m": "°F", "apparent_temperature": "°C", "wind_speed_10m": "m/s"]
        XCTAssertThrowsError(try OpenMeteoWeather.parse(data(raw), latitude: 0, longitude: 0, city: "Fixture", now: now))
        XCTAssertThrowsError(try OpenMeteoWeather.parse(data(Self.fixture(now: now.addingTimeInterval(-86400))), latitude: 0, longitude: 0, city: "Fixture", now: now))
        XCTAssertThrowsError(try OpenMeteoWeather.parse(Data(repeating: 32, count: OpenMeteoWeather.maximumResponseBytes + 1), latitude: 0, longitude: 0, city: "Fixture", now: now))
        raw = Self.fixture(now: now)
        var current = raw["current"] as! [String: Any]; current["temperature_2m"] = true; raw["current"] = current
        XCTAssertThrowsError(try OpenMeteoWeather.parse(data(raw), latitude: 0, longitude: 0, city: "Fixture", now: now))
    }

    func testMalformedOptionalSeriesCannotEraseCurrentConditionsOrAlerts() throws {
        let now = Date(); var raw = Self.fixture(now: now)
        var hours = raw["hourly"] as! [String: Any]; hours["temperature_2m"] = [42]; raw["hourly"] = hours
        raw["utc_offset_seconds"] = "Asia/Shanghai"
        let value = try OpenMeteoWeather.parse(data(raw), latitude: 0, longitude: 0, city: "Fixture", now: now)
        XCTAssertEqual(value.current.temperatureC, 20); XCTAssertTrue(value.hourly.isEmpty); XCTAssertTrue(value.daily.isEmpty)
        XCTAssertEqual(Set(value.unavailableSections), Set(["alerts", "hourly", "daily"]))
        XCTAssertNil(value.alerts); XCTAssertNil(value.current.highC)
    }

    func testEmptyTimeOnlyAndNullForecastsAreUnavailable() throws {
        let now = Date(timeIntervalSince1970: 1_704_040_200)
        let future = now.addingTimeInterval(3600).timeIntervalSince1970
        let invalidHours: [[String: Any]] = [
            ["time": []],
            ["time": [future]],
            ["time": [future], "temperature_2m": [NSNull()], "weather_code": [NSNull()]],
            ["time": [future], "temperature_2m": [21], "weather_code": [NSNull()]],
            ["time": [future], "temperature_2m": [NSNull()], "weather_code": [0]],
            ["time": [now.addingTimeInterval(-3600).timeIntervalSince1970], "temperature_2m": [21], "weather_code": [0]]
        ]
        for hourly in invalidHours {
            var raw = Self.fixture(now: now); raw["hourly"] = hourly
            let value = try OpenMeteoWeather.parse(data(raw), latitude: 31, longitude: 121, city: "Fixture", now: now)
            XCTAssertTrue(value.hourly.isEmpty)
            XCTAssertTrue(value.unavailableSections.contains("hourly"))
            XCTAssertEqual(value.current.temperatureC, 20)
            XCTAssertEqual(value.daily.count, 2)
            XCTAssertNil(value.alerts)
        }
        let invalidDays: [[String: Any]] = [
            ["time": []],
            ["time": [future]],
            ["time": [future], "temperature_2m_max": [NSNull()], "temperature_2m_min": [NSNull()], "weather_code": [NSNull()]],
            ["time": [future], "temperature_2m_max": [25], "temperature_2m_min": [15], "weather_code": [NSNull()]]
        ]
        for daily in invalidDays {
            var raw = Self.fixture(now: now); raw["daily"] = daily
            let value = try OpenMeteoWeather.parse(data(raw), latitude: 31, longitude: 121, city: "Fixture", now: now)
            XCTAssertTrue(value.daily.isEmpty)
            XCTAssertTrue(value.unavailableSections.contains("daily"))
            XCTAssertEqual(value.current.temperatureC, 20)
            XCTAssertNil(value.current.highC)
            XCTAssertEqual(value.hourly.count, 2)
            XCTAssertNil(value.alerts)
        }
    }

    @MainActor private func fixtureClient() -> (OpenMeteoWeatherClient, URLSession) {
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [OpenMeteoHTTP.self]
        let session = URLSession(configuration: config)
        return (OpenMeteoWeatherClient(session: session), session)
    }

    @MainActor func testTransportHasNoGarminCredentialsOrDeviceHeaders() async throws {
        OpenMeteoHTTP.reset()
        let (client, session) = fixtureClient(); defer { client.cancel(); session.invalidateAndCancel() }
        let result = try await client.fetch(latitude: 31, longitude: 121, city: "Fixture")
        XCTAssertEqual(result.current.temperatureC, 20)
        XCTAssertEqual(OpenMeteoHTTP.requests.count, 1)
        let request = try XCTUnwrap(OpenMeteoHTTP.requests.first)
        XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
        XCTAssertNil(request.value(forHTTPHeaderField: "Cookie"))
        XCTAssertNil(request.value(forHTTPHeaderField: "X-Garmin-Unit-ID"))
        XCTAssertEqual(request.url?.host, "api.open-meteo.com")
    }

    @MainActor func testCancelDiscardsInFlightWeather() async throws {
        OpenMeteoHTTP.reset(stall: true)
        let (client, session) = fixtureClient(); defer { session.invalidateAndCancel() }
        let pending = Task { try await client.fetch(latitude: 31, longitude: 121, city: "Fixture") }
        for _ in 0..<100 {
            if !OpenMeteoHTTP.requests.isEmpty { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertEqual(OpenMeteoHTTP.requests.count, 1)
        client.cancel()
        do { _ = try await pending.value; XCTFail("Cancelled request returned weather") }
        catch { XCTAssertTrue(error is CancellationError) }
    }

    @MainActor func testRedirectResponseFailsWithoutFollowingDestination() async throws {
        OpenMeteoHTTP.reset(status: 302)
        let (client, session) = fixtureClient(); defer { client.cancel(); session.invalidateAndCancel() }
        do { _ = try await client.fetch(latitude: 31, longitude: 121, city: "Fixture"); XCTFail("Redirect must fail") }
        catch { XCTAssertTrue(error is GarminWeatherError) }
        XCTAssertEqual(OpenMeteoHTTP.requests.count, 1)
    }
}

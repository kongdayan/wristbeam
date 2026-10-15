import Foundation
import XCTest
@testable import GarminBar

private final class WeatherHTTP: URLProtocol {
    private static let lock = NSLock()
    private static var weatherCode = 200
    private static var alertCode = 200
    private static var stallCurrent = false
    private static var seen: [URLRequest] = []
    static func reset(weather: Int = 200, alerts: Int = 200, stall: Bool = false) {
        lock.lock(); defer { lock.unlock() }; weatherCode = weather; alertCode = alerts; seen = []; stallCurrent = stall
    }
    static var requests: [URLRequest] { lock.lock(); defer { lock.unlock() }; return seen }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.lock.lock(); Self.seen.append(request); let weather = Self.weatherCode, alerts = Self.alertCode, stall = Self.stallCurrent; Self.lock.unlock()
        let path = request.url!.path
        if stall && path.hasSuffix("/current") { return }
        var code = 200
        let json: String
        if path.contains("socialProfile") { json = #"{"garminGUID":"weather-fixture","displayName":"Fixture"}"# }
        else if path.contains("deviceregistration") { json = "[]" }
        else if path.hasSuffix("/current") {
            code = weather
            json = "{\"epochSeconds\":\(Int(Date().timeIntervalSince1970)),\"temperature\":{\"value\":21,\"units\":\"CELSIUS\"},\"icon\":28}"
        } else if path.hasSuffix("/alerts") { code = alerts; json = "[]" }
        else { json = "[]" }
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: code, httpVersion: nil,
            headerFields: ["Content-Type": "application/json"])!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(json.utf8)); client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

final class WeatherCloudTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private func data(_ object: Any) throws -> Data { try JSONSerialization.data(withJSONObject: object) }

    func testRegionalWeatherURLsUseSignedSemicirclesAndBoundDuration() throws {
        let china = try GarminWeatherAPI.url(section: .hourly, region: .china, latitude: -45, longitude: 90, forecastHours: 999)
        XCTAssertEqual(china.host, "api.gcs.garmin.cn")
        XCTAssertEqual(china.path, "/weather/v2/forecast/hour")
        let query = Dictionary(uniqueKeysWithValues: URLComponents(url: china, resolvingAgainstBaseURL: false)!.queryItems!.map { ($0.name, $0.value!) })
        XCTAssertEqual(query["lat"], "-536870912"); XCTAssertEqual(query["lon"], "1073741824")
        XCTAssertEqual(query["duration"], "48"); XCTAssertEqual(query["tempUnit"], "CELSIUS")
        XCTAssertEqual(query["speedUnit"], "METERS_PER_SECOND")
        let global = try GarminWeatherAPI.url(section: .alerts, region: .global, latitude: 0, longitude: 0)
        XCTAssertEqual(global.host, "api.gcs.garmin.com")
        XCTAssertFalse(global.absoluteString.contains("tempUnit"))
        for latitude in [Double.nan, .infinity, -91, 91] {
            XCTAssertThrowsError(try GarminWeatherAPI.url(section: .current, region: .china, latitude: latitude, longitude: 0))
        }
        XCTAssertThrowsError(try GarminWeatherAPI.url(section: .current, region: .china, latitude: 0, longitude: 181))
    }

    func testConditionsConvertUnitsIconsAndRejectBooleanMeasurements() throws {
        let raw: [String: Any] = ["epochSeconds": now.timeIntervalSince1970, "temperature": ["value": 77, "units": "FAHRENHEIT"],
            "feelsLikeTemperature": ["value": 300.15, "units": "KELVIN"], "icon": 28, "relativeHumidity": true,
            "wind": ["speed": ["value": 36, "units": "KILOMETERS_PER_HOUR"], "direction": 270]]
        let value = try GarminWeatherAPI.current(data(raw), now: now)
        XCTAssertEqual(value.temperatureC, 25); XCTAssertEqual(value.feelsLikeC!, 27, accuracy: 0.001)
        XCTAssertEqual(value.windSpeedMPS, 10); XCTAssertEqual(value.condition, 3)
        XCTAssertNil(value.relativeHumidity)
        var missing = raw; missing["temperature"] = ["value": 20, "units": "unknown"]
        XCTAssertThrowsError(try GarminWeatherAPI.current(data(missing), now: now))
        var stale = raw; stale["epochSeconds"] = now.addingTimeInterval(-86400).timeIntervalSince1970
        XCTAssertThrowsError(try GarminWeatherAPI.current(data(stale), now: now))
    }

    func testForecastWeekdayAndMissingValuesAreNotInvented() throws {
        let raw: [[String: Any]] = [["dayOfWeek": 7, "high": ["value": 25, "units": "CELSIUS"], "icon": 15],
                                   ["dayOfWeek": 1, "low": ["value": 12, "units": "CELSIUS"], "icon": 254]]
        let days = try GarminWeatherAPI.daily(data(raw), now: now)
        XCTAssertEqual(days.map(\.dayOfWeek), [0, 1]); XCTAssertEqual(days[0].condition, 22)
        XCTAssertNil(days[0].lowC); XCTAssertNil(days[1].condition)
        let hour: [String: Any] = ["epochSeconds": now.addingTimeInterval(3600).timeIntervalSince1970,
                                  "temp": ["value": 23, "units": "CELSIUS"], "uvIndex": 4.5, "airQuality": 3]
        let hours = try GarminWeatherAPI.hourly(data([hour]), now: now)
        XCTAssertEqual(hours[0].uvIndex, 4.5); XCTAssertEqual(hours[0].airQuality, 3)
        XCTAssertThrowsError(try GarminWeatherAPI.hourly(data(Array(repeating: hour, count: 49)), now: now))
        XCTAssertThrowsError(try GarminWeatherAPI.current(Data(repeating: 32, count: GarminWeatherAPI.maximumResponseBytes + 1), now: now))
    }

    func testAlertsDistinguishConfirmedEmptyFromMalformedAndMapFITEnums() throws {
        let alert: [String: Any] = ["id": "fixture-warning", "description": "Wind", "severity": "WARNING", "type": "HIGH_WIND",
            "epochIssuedTime": now.addingTimeInterval(-3600).timeIntervalSince1970,
            "epochExpireTime": now.addingTimeInterval(3600).timeIntervalSince1970]
        let parsed = try GarminWeatherAPI.alerts(data([alert]), now: now)
        XCTAssertEqual(parsed[0].severity, 1); XCTAssertEqual(parsed[0].type, 22)
        XCTAssertEqual(try GarminWeatherAPI.alerts(Data("[]".utf8), now: now), [])
        XCTAssertThrowsError(try GarminWeatherAPI.alerts(Data("{}".utf8), now: now))
        var malformed = alert; malformed["epochExpireTime"] = false
        XCTAssertThrowsError(try GarminWeatherAPI.alerts(data([malformed]), now: now))
        XCTAssertEqual(try GarminWeatherAPI.alerts(data([alert]), now: now.addingTimeInterval(7200)), [])
    }

    @MainActor private func fixture(_ root: URL, networkEnabled: Bool = true) throws -> (GarminChinaCloud, URLSession, String) {
        let auth = root.appendingPathComponent("session.json")
        let token = GarminOAuthToken(accessToken: "fixture-access", refreshToken: "fixture-refresh", clientID: "FIXTURE",
            expiresAt: Date().addingTimeInterval(3600), refreshExpiresAt: nil, scopes: [])
        try GarminPrivateFile.write(JSONEncoder().encode(token), to: auth)
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [WeatherHTTP.self]
        let session = URLSession(configuration: config), domain = "wristbeam.weather-tests.\(UUID().uuidString)"
        return (GarminChinaCloud(storageURL: auth, session: session, automaticallyRestore: false,
                networkEnabled: networkEnabled, preferences: AppPreferences(domain: domain)), session, domain)
    }

    @MainActor func testWeather403KeepsHealthyConnectAccount() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        WeatherHTTP.reset(weather: 403)
        let (cloud, session, domain) = try fixture(root)
        defer { cloud.setNetworkEnabled(false); session.invalidateAndCancel(); UserDefaults.standard.removePersistentDomain(forName: domain) }
        await cloud.refreshAccount(); XCTAssertTrue(cloud.isAuthenticated)
        do { _ = try await cloud.fetchWeather(latitude: 30, longitude: 120, city: "Fixture"); XCTFail("Weather denial must surface") }
        catch { XCTAssertTrue(error is GarminWeatherError) }
        XCTAssertTrue(cloud.isAuthenticated)
        let weather = WeatherHTTP.requests.filter { $0.url?.host == "api.gcs.garmin.cn" }
        XCTAssertEqual(weather.count, 1); XCTAssertEqual(weather.first?.value(forHTTPHeaderField: "Authorization"), "Bearer fixture-access")
        XCTAssertNil(weather.first?.value(forHTTPHeaderField: "X-Garmin-Unit-ID"))
    }

    @MainActor func testOptionalAlertFailureDoesNotClearExistingAlerts() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        WeatherHTTP.reset(alerts: 503)
        let (cloud, session, domain) = try fixture(root)
        defer { cloud.setNetworkEnabled(false); session.invalidateAndCancel(); UserDefaults.standard.removePersistentDomain(forName: domain) }
        await cloud.refreshAccount()
        let snapshot = try await cloud.fetchWeather(latitude: 30, longitude: 120, city: "Fixture")
        XCTAssertEqual(snapshot.current.temperatureC, 21); XCTAssertNil(snapshot.alerts)
        XCTAssertEqual(snapshot.unavailableSections, ["alerts"]); XCTAssertTrue(cloud.isAuthenticated)
        WeatherHTTP.reset()
        let empty = try await cloud.fetchWeather(latitude: 30, longitude: 120, city: "Fixture")
        XCTAssertEqual(empty.alerts, []); XCTAssertTrue(empty.unavailableSections.isEmpty)
    }

    @MainActor func testLocalModeNeverCallsWeatherService() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        WeatherHTTP.reset()
        let (cloud, session, domain) = try fixture(root, networkEnabled: false)
        defer { session.invalidateAndCancel(); UserDefaults.standard.removePersistentDomain(forName: domain) }
        do { _ = try await cloud.fetchWeather(latitude: 30, longitude: 120, city: "Fixture"); XCTFail("Local mode must stop weather") }
        catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertEqual(WeatherHTTP.requests.count, 0)
    }

    @MainActor func testPausingCloudCancelsPendingWeatherAndCannotReturnStaleSnapshot() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        WeatherHTTP.reset(stall: true)
        let (cloud, session, domain) = try fixture(root)
        defer { session.invalidateAndCancel(); UserDefaults.standard.removePersistentDomain(forName: domain) }
        await cloud.refreshAccount()
        let pending = Task { try await cloud.fetchWeather(latitude: 30, longitude: 120, city: "Fixture") }
        for _ in 0..<100 {
            if WeatherHTTP.requests.contains(where: { $0.url?.path.hasSuffix("/current") == true }) { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertTrue(WeatherHTTP.requests.contains { $0.url?.path.hasSuffix("/current") == true })
        cloud.setNetworkEnabled(false)
        do { _ = try await pending.value; XCTFail("Paused weather must not deliver") }
        catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertFalse(WeatherHTTP.requests.contains { $0.url?.path.contains("/forecast/") == true })
    }
}

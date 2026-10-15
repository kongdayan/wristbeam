import Foundation
import CoreFoundation

private final class OpenMeteoNoRedirect: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

/// Independent, opt-in weather transport. Never receives Garmin tokens or device identifiers.
/// Free endpoint: non-commercial use, CC-BY 4.0 attribution required.
/// https://open-meteo.com/en/docs · https://open-meteo.com/en/terms
@MainActor
final class OpenMeteoWeatherClient {
    private var session: URLSession
    private var generation = UUID()
    init(session: URLSession? = nil) { self.session = session ?? Self.makeSession() }
    deinit { session.invalidateAndCancel() }

    func cancel() {
        generation = UUID()
        let configuration = session.configuration
        session.invalidateAndCancel()
        session = URLSession(configuration: configuration, delegate: OpenMeteoNoRedirect(), delegateQueue: nil)
    }

    func fetch(latitude: Double, longitude: Double, city: String) async throws -> WatchWeatherSnapshot {
        let identity = generation
        let url = try OpenMeteoWeather.url(latitude: latitude, longitude: longitude)
        var request = URLRequest(url: url)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("WristBeam", forHTTPHeaderField: "User-Agent")
        do {
            try Task.checkCancellation()
            let (bytes, response) = try await session.bytes(for: request)
            guard identity == generation else { throw CancellationError() }
            guard let http = response as? HTTPURLResponse else { throw GarminWeatherError.invalidResponse }
            guard http.url?.scheme == "https", http.url?.host == "api.open-meteo.com", http.url?.path == "/v1/forecast" else { throw GarminWeatherError.redirected }
            if (300..<400).contains(http.statusCode) { throw GarminWeatherError.redirected }
            guard http.statusCode == 200 else { throw GarminWeatherError.unavailable }
            guard http.expectedContentLength <= OpenMeteoWeather.maximumResponseBytes else { throw GarminWeatherError.invalidResponse }
            var data = Data()
            for try await byte in bytes {
                guard identity == generation, !Task.isCancelled else { throw CancellationError() }
                guard data.count < OpenMeteoWeather.maximumResponseBytes else { throw GarminWeatherError.invalidResponse }
                data.append(byte)
            }
            guard identity == generation, !Task.isCancelled else { throw CancellationError() }
            return try OpenMeteoWeather.parse(data, latitude: latitude, longitude: longitude, city: city, now: Date())
        } catch {
            if identity != generation || Task.isCancelled || error is CancellationError { throw CancellationError() }
            if let weatherError = error as? GarminWeatherError { throw weatherError }
            throw GarminWeatherError.unavailable
        }
    }

    private static func makeSession() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.httpCookieStorage = nil; config.urlCache = nil
        config.timeoutIntervalForRequest = 20; config.timeoutIntervalForResource = 45
        return URLSession(configuration: config, delegate: OpenMeteoNoRedirect(), delegateQueue: nil)
    }
}

enum OpenMeteoWeather {
    static let maximumResponseBytes = 512 * 1024
    static func url(latitude: Double, longitude: Double) throws -> URL {
        guard latitude.isFinite, longitude.isFinite, (-90...90).contains(latitude), (-180...180).contains(longitude) else { throw GarminWeatherError.invalidLocation }
        var components = URLComponents(string: "https://api.open-meteo.com/v1/forecast")!
        components.queryItems = [
            .init(name: "latitude", value: String(latitude)), .init(name: "longitude", value: String(longitude)),
            .init(name: "current", value: "temperature_2m,relative_humidity_2m,apparent_temperature,weather_code,wind_speed_10m,wind_direction_10m"),
            .init(name: "hourly", value: "temperature_2m,relative_humidity_2m,apparent_temperature,weather_code,wind_speed_10m,wind_direction_10m,precipitation_probability,dew_point_2m,uv_index"),
            .init(name: "daily", value: "weather_code,temperature_2m_max,temperature_2m_min,precipitation_probability_max"),
            .init(name: "temperature_unit", value: "celsius"), .init(name: "wind_speed_unit", value: "ms"),
            .init(name: "timeformat", value: "unixtime"), .init(name: "timezone", value: "auto"),
            .init(name: "forecast_days", value: "5")
        ]
        return components.url!
    }

    static func parse(_ data: Data, latitude: Double, longitude: Double, city: String, now: Date) throws -> WatchWeatherSnapshot {
        _ = try url(latitude: latitude, longitude: longitude)
        guard !data.isEmpty, data.count <= maximumResponseBytes,
              let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let current = root["current"] as? [String: Any],
              let timestamp = date(current["time"]),
              let units = root["current_units"] as? [String: String],
              units["temperature_2m"] == "°C", units["apparent_temperature"] == "°C",
              units["wind_speed_10m"] == "m/s", units["time"] == "unixtime" else { throw GarminWeatherError.invalidResponse }
        guard timestamp >= now.addingTimeInterval(-10800), timestamp <= now.addingTimeInterval(3600) else { throw GarminWeatherError.staleResponse }
        let condition = conditions(current, time: timestamp)
        guard condition.temperatureC != nil else { throw GarminWeatherError.invalidResponse }
        var result = WatchWeatherSnapshot(location: .init(name: String(city.prefix(100)), latitude: latitude, longitude: longitude), fetchedAt: now, current: condition)
        // Forecast API has no severe-alert feed. nil explicitly preserves watch alerts.
        result.unavailableSections = ["alerts"]
        do { result.hourly = try hourly(root, now: now) }
        catch { result.unavailableSections.append("hourly") }
        do { result.daily = try daily(root, now: now) }
        catch { result.unavailableSections.append("daily") }
        result.current.highC = result.daily.first?.highC
        result.current.lowC = result.daily.first?.lowC
        result.current.precipitationProbability = result.daily.first?.precipitationProbability
        return result
    }

    private static func hourly(_ root: [String: Any], now: Date) throws -> [WatchWeatherSnapshot.Conditions] {
        guard let object = root["hourly"] as? [String: Any], let times = object["time"] as? [Any], !times.isEmpty, times.count <= 144,
              let units = root["hourly_units"] as? [String: String], units["time"] == "unixtime",
              units["temperature_2m"] == "°C", units["apparent_temperature"] == "°C",
              units["dew_point_2m"] == "°C", units["wind_speed_10m"] == "m/s" else { throw GarminWeatherError.invalidResponse }
        let values = try rows(object, times: times)
        var output: [WatchWeatherSnapshot.Conditions] = []
        var last = Date.distantPast
        for (time, row) in values {
            guard time > last, time >= now.addingTimeInterval(-86400), time <= now.addingTimeInterval(6 * 86400) else { throw GarminWeatherError.invalidResponse }
            last = time
            if time >= now && output.count < 48 {
                let value = conditions(row, time: time)
                guard value.temperatureC != nil, value.condition != nil else { throw GarminWeatherError.invalidResponse }
                output.append(value)
            }
        }
        guard !output.isEmpty else { throw GarminWeatherError.invalidResponse }
        return output
    }

    private static func daily(_ root: [String: Any], now: Date) throws -> [WatchWeatherSnapshot.Conditions] {
        guard let object = root["daily"] as? [String: Any], let times = object["time"] as? [Any], !times.isEmpty, times.count <= 5,
              let offset = number(root["utc_offset_seconds"], range: -64800...64800), offset.rounded(.towardZero) == offset,
              let zone = TimeZone(secondsFromGMT: Int(offset)),
              let units = root["daily_units"] as? [String: String], units["time"] == "unixtime",
              units["temperature_2m_max"] == "°C", units["temperature_2m_min"] == "°C" else { throw GarminWeatherError.invalidResponse }
        // API daily boundaries use one returned offset throughout the response, even across DST.
        // This reproduces forecast dates without using the Mac's current time zone.
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = zone
        var last = Date.distantPast
        return try rows(object, times: times).map { time, row in
            guard time > last, time >= now.addingTimeInterval(-86400), time <= now.addingTimeInterval(6 * 86400) else { throw GarminWeatherError.invalidResponse }
            last = time
            var value = WatchWeatherSnapshot.Conditions(timestamp: time)
            value.dayOfWeek = UInt8(calendar.component(.weekday, from: time) - 1)
            value.highC = number(row["temperature_2m_max"], range: -100...100)
            value.lowC = number(row["temperature_2m_min"], range: -100...100)
            value.condition = weatherCode(row["weather_code"])
            value.precipitationProbability = number(row["precipitation_probability_max"], range: 0...100)
            guard value.highC != nil, value.lowC != nil, value.condition != nil else { throw GarminWeatherError.invalidResponse }
            return value
        }
    }

    private static func rows(_ object: [String: Any], times: [Any]) throws -> [(Date, [String: Any])] {
        var arrays: [String: [Any]] = [:]
        for (key, value) in object where key != "time" {
            guard let array = value as? [Any], array.count == times.count else { throw GarminWeatherError.invalidResponse }
            arrays[key] = array
        }
        return try times.enumerated().map { index, raw in
            guard let time = date(raw) else { throw GarminWeatherError.invalidResponse }
            return (time, arrays.mapValues { $0[index] })
        }
    }

    private static func conditions(_ object: [String: Any], time: Date) -> WatchWeatherSnapshot.Conditions {
        var value = WatchWeatherSnapshot.Conditions(timestamp: time)
        value.temperatureC = number(object["temperature_2m"], range: -100...100)
        value.feelsLikeC = number(object["apparent_temperature"], range: -100...100)
        value.relativeHumidity = number(object["relative_humidity_2m"], range: 0...100)
        value.windSpeedMPS = number(object["wind_speed_10m"], range: 0...150)
        value.windDirectionDegrees = number(object["wind_direction_10m"], range: 0...360)
        value.precipitationProbability = number(object["precipitation_probability"], range: 0...100)
        value.dewPointC = number(object["dew_point_2m"], range: -100...100)
        value.uvIndex = number(object["uv_index"], range: 0...30)
        value.condition = weatherCode(object["weather_code"])
        return value
    }

    /// WMO interpretation → nearest FIT weather_status. No condition implies an alert.
    private static func weatherCode(_ object: Any?) -> UInt8? {
        guard let value = number(object, range: 0...99), value.rounded(.towardZero) == value else { return nil }
        switch Int(value) {
        case 0, 1: return 0
        case 2: return 1
        case 3: return 22
        case 45, 48: return 8
        case 51, 53, 55, 61: return 16
        case 56, 57, 66, 67: return 7
        case 63: return 3
        case 65, 82: return 17
        case 71, 85: return 18
        case 73, 77: return 4
        case 75, 86: return 19
        case 80, 81: return 13
        case 95, 97: return 6
        case 96, 99: return 12
        default: return nil
        }
    }
    private static func date(_ object: Any?) -> Date? {
        number(object, range: 631065600...4102444800).map { Date(timeIntervalSince1970: $0) }
    }
    private static func number(_ object: Any?, range: ClosedRange<Double>) -> Double? {
        guard let value = object as? NSNumber, CFGetTypeID(value) != CFBooleanGetTypeID(), value.doubleValue.isFinite,
              range.contains(value.doubleValue) else { return nil }
        return value.doubleValue
    }
}

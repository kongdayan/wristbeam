import Foundation
import CoreFoundation

/// Weather service contract recovered from the Android weather library (js2/ms2).
/// Parsing has no network side effects and never substitutes missing measurements with zero.
enum GarminWeatherError: LocalizedError {
    case invalidLocation, invalidResponse, staleResponse, accessDenied, unavailable, redirected
    var errorDescription: String? {
        switch self {
        case .invalidLocation: return "天气位置无效，请重新选择城市"
        case .invalidResponse: return "天气数据格式不完整，请稍后重试"
        case .staleResponse: return "天气数据已过期，请稍后重试"
        case .accessDenied: return "当前账户无法访问天气服务，请检查云账号"
        case .unavailable: return "天气服务暂时不可用，请稍后重试"
        case .redirected: return "天气请求被重定向，请稍后重试"
        }
    }
}

enum GarminWeatherAPI {
    enum Section: String, CaseIterable { case current, hourly, daily, alerts }
    static let maximumResponseBytes = 512 * 1024

    static func url(section: Section, region: GarminRegion, latitude: Double, longitude: Double,
                    forecastHours: Int = 24) throws -> URL {
        guard latitude.isFinite, longitude.isFinite, (-90...90).contains(latitude),
              (-180...180).contains(longitude) else { throw GarminWeatherError.invalidLocation }
        let path: String
        switch section {
        case .current: path = "current"
        case .hourly: path = "forecast/hour"
        case .daily: path = "forecast/day"
        case .alerts: path = "alerts"
        }
        var components = URLComponents(string: "https://api.gcs.\(region.domain)/weather/v2/\(path)")!
        // APK hs2.h.e uses signed 64-bit semicircles, truncating toward zero.
        components.queryItems = [URLQueryItem(name: "lat", value: String(Int64(latitude * 2147483648 / 180))),
                                 URLQueryItem(name: "lon", value: String(Int64(longitude * 2147483648 / 180)))]
        if section == .hourly || section == .daily {
            components.queryItems?.append(URLQueryItem(name: "duration", value: String(section == .daily ? 5 : max(1, min(48, forecastHours)))))
        }
        if section != .alerts { components.queryItems?.append(URLQueryItem(name: "tempUnit", value: "CELSIUS")) }
        if section == .current || section == .hourly { components.queryItems?.append(URLQueryItem(name: "speedUnit", value: "METERS_PER_SECOND")) }
        guard let url = components.url, GarminChinaURLPolicy.isTrusted(url, region: region) else { throw GarminWeatherError.invalidLocation }
        return url
    }

    static func current(_ data: Data, now: Date) throws -> WatchWeatherSnapshot.Conditions {
        guard let object = try json(data) as? [String: Any] else { throw GarminWeatherError.invalidResponse }
        let value = try conditions(object, hourly: false, now: now)
        guard value.temperatureC != nil else { throw GarminWeatherError.invalidResponse }
        return value
    }

    static func hourly(_ data: Data, now: Date) throws -> [WatchWeatherSnapshot.Conditions] {
        try objects(data, maximum: 48).map { try conditions($0, hourly: true, now: now) }
    }

    static func daily(_ data: Data, now: Date) throws -> [WatchWeatherSnapshot.Conditions] {
        try objects(data, maximum: 10).map { object in
            guard let day = integer(object["dayOfWeek"], range: 1...7) else { throw GarminWeatherError.invalidResponse }
            // The daily API supplies weekday, not an epoch. FIT daily records use weekday;
            // timestamp denotes retrieval time, never an invented forecast instant.
            var value = WatchWeatherSnapshot.Conditions(timestamp: now)
            value.dayOfWeek = UInt8(day == 7 ? 0 : day)
            value.highC = temperature(object["high"]); value.lowC = temperature(object["low"])
            value.condition = condition(object["icon"])
            value.precipitationProbability = number(object["precipProb"], range: 0...100)
            guard value.highC != nil || value.lowC != nil else { throw GarminWeatherError.invalidResponse }
            return value
        }
    }

    static func alerts(_ data: Data, now: Date) throws -> [WatchWeatherSnapshot.Alert] {
        let severity: [String: UInt8] = ["UNKNOWN": 0, "WARNING": 1, "WATCH": 2, "ADVISORY": 3, "STATEMENT": 4]
        return try objects(data, maximum: 100).compactMap { object in
            guard let identifier = text(object["id"], maximum: 128), !identifier.isEmpty,
                  let issued = date(object["epochIssuedTime"]), let expires = date(object["epochExpireTime"]),
                  expires > issued else { throw GarminWeatherError.invalidResponse }
            guard expires > now else { return nil }
            guard issued <= now.addingTimeInterval(3600), expires <= now.addingTimeInterval(90 * 86400) else { throw GarminWeatherError.invalidResponse }
            var value = WatchWeatherSnapshot.Alert(identifier: identifier)
            value.issuedAt = issued; value.expiresAt = expires
            value.severity = (object["severity"] as? String).flatMap { severity[$0] }
            value.type = (object["type"] as? String).flatMap { alertTypes[$0] }
            value.description = text(object["description"], maximum: 256)
            return value
        }
    }

    private static func conditions(_ object: [String: Any], hourly: Bool, now: Date) throws -> WatchWeatherSnapshot.Conditions {
        guard let timestamp = date(object["epochSeconds"]) else { throw GarminWeatherError.invalidResponse }
        let age = timestamp.timeIntervalSince(now)
        guard age >= (hourly ? -7200 : -10800), age <= (hourly ? 72 * 3600 : 3600) else { throw GarminWeatherError.staleResponse }
        var value = WatchWeatherSnapshot.Conditions(timestamp: timestamp)
        value.temperatureC = temperature(object[hourly ? "temp" : "temperature"])
        value.feelsLikeC = temperature(object["feelsLikeTemperature"])
        value.dewPointC = temperature(object["dewPoint"])
        value.condition = condition(object["icon"])
        value.relativeHumidity = number(object["relativeHumidity"], range: 0...100)
        value.precipitationProbability = number(object["precipProb"], range: 0...100)
        value.uvIndex = number(object["uvIndex"], range: 0...30)
        value.airQuality = integer(object["airQuality"], range: 0...5).map(UInt8.init)
        if let wind = object["wind"] as? [String: Any] {
            value.windDirectionDegrees = number(wind["direction"], range: 0...360)
            if let speed = wind["speed"] as? [String: Any], let raw = number(speed["value"], range: 0...1000),
               let unit = speed["units"] as? String {
                let multiplier: Double?
                switch unit {
                case "METERS_PER_SECOND": multiplier = 1
                case "KILOMETERS_PER_HOUR": multiplier = 1 / 3.6
                case "MILES_PER_HOUR": multiplier = 0.44704
                case "KNOTS": multiplier = 0.514444
                case "FEET_PER_SECOND": multiplier = 0.3048
                case "CENTIMETERS_PER_MILLISECOND": multiplier = 10
                default: multiplier = nil
                }
                if let multiplier, raw * multiplier <= 150 { value.windSpeedMPS = raw * multiplier }
            }
        }
        return value
    }

    private static func temperature(_ object: Any?) -> Double? {
        guard let measure = object as? [String: Any], let raw = number(measure["value"], range: -500...1000),
              let units = measure["units"] as? String else { return nil }
        let celsius: Double
        switch units {
        case "CELSIUS": celsius = raw
        case "FAHRENHEIT": celsius = (raw - 32) * 5 / 9
        case "KELVIN": celsius = raw - 273.15
        default: return nil
        }
        return (-100...100).contains(celsius) ? celsius : nil
    }
    private static func date(_ object: Any?) -> Date? {
        number(object, range: 631065600...4102444800).map { Date(timeIntervalSince1970: $0) }
    }
    private static func number(_ object: Any?, range: ClosedRange<Double>) -> Double? {
        guard let value = object as? NSNumber, CFGetTypeID(value) != CFBooleanGetTypeID(),
              value.doubleValue.isFinite, range.contains(value.doubleValue) else { return nil }
        return value.doubleValue
    }
    private static func integer(_ object: Any?, range: ClosedRange<Int>) -> Int? {
        guard let value = number(object, range: Double(range.lowerBound)...Double(range.upperBound)), value.rounded(.towardZero) == value else { return nil }
        return Int(value)
    }
    private static func text(_ object: Any?, maximum: Int) -> String? {
        guard let value = object as? String else { return nil }
        return String(String.UnicodeScalarView(value.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) }.prefix(maximum)))
    }
    private static func json(_ data: Data) throws -> Any {
        guard !data.isEmpty, data.count <= maximumResponseBytes else { throw GarminWeatherError.invalidResponse }
        do { return try JSONSerialization.jsonObject(with: data) }
        catch { throw GarminWeatherError.invalidResponse }
    }
    private static func objects(_ data: Data, maximum: Int) throws -> [[String: Any]] {
        guard let values = try json(data) as? [[String: Any]], values.count <= maximum else { throw GarminWeatherError.invalidResponse }
        return values
    }

    /// APK is2.a.b translates weather-provider icons to the FIT weather_status enum.
    private static func condition(_ object: Any?) -> UInt8? {
        guard let icon = integer(object, range: 0...254) else { return nil }
        switch icon {
        case 0, 3...6: return 0
        case 7...10: return 1
        case 11, 12: return 11
        case 13, 14: return 2
        case 15, 16: return 22
        case 17: return 15
        case 18...21: return 13
        case 22: return 16
        case 23...26: return 14
        case 27: return 6
        case 28: return 3
        case 29: return 17
        case 30...34: return 18
        case 35...37: return 4
        case 38: return 19
        case 39...41: return 7
        case 42: return 20
        case 43: return 21
        case 44, 45: return 12
        case 46: return 5
        case 47, 48: return 8
        default: return nil
        }
    }

    // APK ks2.b: FIT weather_severe_type values, unrelated to provider icon numbers.
    private static let alertTypes: [String: UInt8] = [
        "TORNADO":1, "TSUNAMI":2, "HURRICANE":3, "EXTREME_WIND":4, "TYPHOON":5,
        "INLAND_HURRICANE":6, "HURRICANE_FORCE_WIND":7, "WATERSPOUT":8, "SEVERE_THUNDERSTORM":9,
        "WRECKHOUSE_WINDS":10, "LES_SUETES_WIND":11, "AVALANCHE":12, "FLASH_FLOOD":13,
        "TROPICAL_STORM":14, "INLAND_TROPICAL_STORM":15, "BLIZZARD":16, "ICE_STORM":17,
        "FREEZING_RAIN":18, "DEBRIS_FLOW":19, "FLASH_FREEZE":20, "DUST_STORM":21, "HIGH_WIND":22,
        "WINTER_STORM":23, "HEAVY_FREEZING_SPRAY":24, "EXTREME_COLD":25, "WIND_CHILL":26,
        "COLD_WAVE":27, "HEAVY_SNOW":28, "LAKE_EFFECT_BLOWING_SNOW":29, "SNOW_SQUALL":30,
        "LAKE_EFFECT_SNOW":31, "WINTER_WEATHER":32, "SLEET":33, "SNOWFALL":34,
        "SNOW_AND_BLOWING_SNOW":35, "BLOWING_SNOW":36, "SNOW":37, "ARCTIC_OUTFLOW":38,
        "FREEZING_DRIZZLE":39, "STORM":40, "STORM_SURGE":41, "RAINFALL":42, "AREAL_FLOOD":43,
        "COASTAL_FLOOD":44, "LAKESHORE_FLOOD":45, "EXCESSIVE_HEAT":46, "HEAT":47, "WEATHER":48,
        "HIGH_HEAT_AND_HUMIDITY":49, "HUMIDEX_AND_HEALTH":50, "HUMIDEX":51, "GALE":52,
        "FREEZING_SPRAY":53, "SPECIAL_MARINE":54, "SQUALL":55, "STRONG_WIND":56, "LAKE_WIND":57,
        "MARINE_WEATHER":58, "WIND":59, "SMALL_CRAFT_HAZARDOUS_SEAS":60, "HAZARDOUS_SEAS":61,
        "SMALL_CRAFT":62, "SMALL_CRAFT_WINDS":63, "SMALL_CRAFT_ROUGH_BAR":64, "HIGH_WATER_LEVEL":65,
        "ASHFALL":66, "FREEZING_FOG":67, "DENSE_FOG":68, "DENSE_SMOKE":69, "BLOWING_DUST":70,
        "HARD_FREEZE":71, "FREEZE":72, "FROST":73, "FIRE_WEATHER":74, "FLOOD":75, "RIP_TIDE":76,
        "HIGH_SURF":77, "SMOG":78, "AIR_QUALITY":79, "BRISK_WIND":80, "AIR_STAGNATION":81,
        "LOW_WATER":82, "HYDROLOGICAL":83, "SPECIAL_WEATHER":84
    ]
}

import Foundation

/// Provider-neutral values in Celsius, metres/second and degrees. FIT enums are mapped by the provider.
struct WatchWeatherSnapshot: Codable, Equatable {
    struct Location: Codable, Equatable {
        var name: String
        var latitude: Double
        var longitude: Double
    }

    struct Conditions: Codable, Equatable {
        /// Forecast time for hourly data; generation time for daily data (dayOfWeek identifies the day).
        var timestamp: Date
        var temperatureC: Double? = nil
        var feelsLikeC: Double? = nil
        var condition: UInt8? = nil
        var windDirectionDegrees: Double? = nil
        var windSpeedMPS: Double? = nil
        var precipitationProbability: Double? = nil
        var relativeHumidity: Double? = nil
        var highC: Double? = nil
        var lowC: Double? = nil
        var dewPointC: Double? = nil
        var uvIndex: Double? = nil
        var airQuality: UInt8? = nil
        /// Sunday = 0, Saturday = 6. Never infer this using the Mac's time zone.
        var dayOfWeek: UInt8? = nil
    }

    struct Alert: Codable, Equatable {
        var identifier: String
        var issuedAt: Date? = nil
        var expiresAt: Date? = nil
        var severity: UInt8? = nil
        var type: UInt8? = nil
        var description: String? = nil
    }

    var location: Location
    var fetchedAt: Date
    var current: Conditions
    var hourly: [Conditions] = []
    var daily: [Conditions] = []
    /// nil means unavailable; [] means the provider returned no active alerts.
    var alerts: [Alert]? = nil
    var unavailableSections: [String] = []
}

enum GFDIWeatherError: Error, Equatable {
    case malformedRequest
    case unsupportedFormat(UInt8)
}

struct GFDIWeatherRequest: Equatable {
    let format: UInt8
    let latitude: Double?
    let longitude: Double?
    let forecastHours: Int

    init(payload: Data) throws {
        guard payload.count == 10 else { throw GFDIWeatherError.malformedRequest }
        var reader = GFDIReader(payload)
        format = try reader.u8()
        guard format == 0 else { throw GFDIWeatherError.unsupportedFormat(format) }
        let lat = try reader.u32()
        let lon = try reader.u32()
        latitude = Self.coordinate(lat, maximum: 90)
        longitude = Self.coordinate(lon, maximum: 180)
        forecastHours = Int(try reader.u8())
    }

    /// is2/c: data available, current/forecast message groups, 300-second timeout (little endian).
    var acknowledgementPayload: Data { Data([128, forecastHours > 0 ? 2 : 1, 0x2c, 0x01]) }

    private static func coordinate(_ raw: UInt32, maximum: Double) -> Double? {
        guard raw != 0x7fffffff else { return nil }
        let value = Double(Int32(bitPattern: raw)) * 180 / 2147483648
        return abs(value) <= maximum ? value : nil
    }
}

/// Independent encoder derived from APK is2/a, hq2/a20, y10, fk and bk.
/// These are FIT records inside GFDI 5011/5012, not a .FIT file (no file header or file CRC).
enum GFDIWeather {
    static let fitEpoch: TimeInterval = 631_065_600

    private struct Field {
        let number: UInt8
        let type: UInt8
        let bytes: [UInt8]
    }

    /// Ordered messages. Caller must wait for the outer ACK and FIT status byte before advancing.
    /// No weather network access, device writes or capability negotiation occurs here.
    static func frames(snapshot: WatchWeatherSnapshot, forecastHours: Int) -> [GFDIMessage] {
        var output: [GFDIMessage] = []
        let current = snapshot.current
        let currentFields = [
            byte(0, 0, 0), timestamp(253, snapshot.fetchedAt), timestamp(9, current.timestamp),
            temperature(1, current.temperatureC), temperature(14, current.lowC), temperature(13, current.highC),
            condition(current.condition), unsigned16(3, current.windDirectionDegrees, maximum: 360),
            percent(5, current.precipitationProbability), speed(current.windSpeedMPS),
            temperature(6, current.feelsLikeC), percent(7, current.relativeHumidity),
            coordinate(10, snapshot.location.latitude, maximum: 90),
            coordinate(11, snapshot.location.longitude, maximum: 180), string(8, snapshot.location.name)
        ]
        append(local: 6, global: 128, records: [currentFields], to: &output)

        let hourly = snapshot.hourly.prefix(max(0, min(48, forecastHours))).map { value in
            [byte(0, 0, 1), timestamp(253, value.timestamp), temperature(1, value.temperatureC),
             condition(value.condition), unsigned16(3, value.windDirectionDegrees, maximum: 360),
             speed(value.windSpeedMPS), percent(5, value.precipitationProbability),
             percent(7, value.relativeHumidity), temperature(15, value.dewPointC),
             float(16, value.uvIndex), byte(17, 0, validEnum(value.airQuality, range: 0...5))]
        }
        append(local: 9, global: 128, records: hourly, to: &output)

        let daily = snapshot.daily.prefix(5).map { value in
            [byte(0, 0, 2), timestamp(253, snapshot.fetchedAt), temperature(14, value.lowC),
             temperature(13, value.highC), condition(value.condition), percent(5, value.precipitationProbability),
             byte(12, 0, validEnum(value.dayOfWeek, range: 0...6))]
        }
        append(local: 10, global: 128, records: daily, to: &output)

        // An absent alert response must never be converted into an invented "all clear" report.
        for alert in (snapshot.alerts ?? []).prefix(10) {
            let fields = [timestamp(253, snapshot.fetchedAt), string(0, alert.identifier),
                          timestamp(1, alert.issuedAt), timestamp(2, alert.expiresAt),
                          byte(3, 0, validEnum(alert.severity, range: 0...4)),
                          byte(4, 0, validEnum(alert.type, range: 0...84))]
            append(local: 5, global: 129, records: [fields], to: &output)
        }
        return output
    }

    private static func append(local: UInt8, global: UInt16, records: [[Field]], to output: inout [GFDIMessage]) {
        guard let fields = records.first else { return }
        // Architecture 1 = big endian, matching the APK FIT writer hq2/fk.
        var definition: [UInt8] = [0x40 | local, 0, 1, UInt8(global >> 8), UInt8(truncatingIfNeeded: global), UInt8(fields.count)]
        for field in fields { definition += [field.number, UInt8(field.bytes.count), field.type] }
        output.append(GFDIMessage(number: 5011, payload: Data(definition)))
        for record in records {
            output.append(GFDIMessage(number: 5012, payload: Data([local] + record.flatMap(\.bytes))))
        }
    }

    private static func byte(_ number: UInt8, _ type: UInt8, _ value: UInt8) -> Field {
        Field(number: number, type: type, bytes: [value])
    }

    private static func be(_ value: UInt32, count: Int = 4) -> [UInt8] {
        stride(from: (count - 1) * 8, through: 0, by: -8).map { UInt8(truncatingIfNeeded: value >> $0) }
    }

    private static func timestamp(_ number: UInt8, _ date: Date?) -> Field {
        let seconds = date.map { ($0.timeIntervalSince1970 - fitEpoch).rounded(.down) }
        let raw: UInt32
        if let seconds, seconds.isFinite, seconds >= 0, seconds < Double(UInt32.max) { raw = UInt32(seconds) }
        else { raw = UInt32.max }
        return Field(number: number, type: 0x86, bytes: be(raw))
    }

    private static func temperature(_ number: UInt8, _ value: Double?) -> Field {
        guard let value, value.isFinite, (-128...126).contains(value.rounded()) else { return byte(number, 1, 0x7f) }
        return byte(number, 1, UInt8(bitPattern: Int8(value.rounded())))
    }

    private static func unsigned16(_ number: UInt8, _ value: Double?, maximum: Double, scale: Double = 1) -> Field {
        let raw: UInt32
        if let value, value.isFinite, value >= 0, value <= maximum, (value * scale).rounded() < 65535 {
            raw = UInt32((value * scale).rounded())
        } else { raw = 65535 }
        return Field(number: number, type: 0x84, bytes: be(raw, count: 2))
    }

    private static func speed(_ value: Double?) -> Field { unsigned16(4, value, maximum: 65.534, scale: 1000) }

    private static func percent(_ number: UInt8, _ value: Double?) -> Field {
        guard let value, value.isFinite, (0...100).contains(value) else { return byte(number, 2, 255) }
        return byte(number, 2, UInt8(value.rounded()))
    }

    private static func condition(_ value: UInt8?) -> Field {
        let known: Set<UInt8> = [0, 1, 2, 3, 4, 5, 6, 7, 8, 11, 12, 13, 14, 15, 16, 17, 18, 19, 20, 21, 22]
        return byte(2, 0, value.flatMap { known.contains($0) ? $0 : nil } ?? 255)
    }

    private static func validEnum(_ value: UInt8?, range: ClosedRange<UInt8>) -> UInt8 {
        value.flatMap { range.contains($0) ? $0 : nil } ?? 255
    }

    private static func coordinate(_ number: UInt8, _ value: Double, maximum: Double) -> Field {
        let raw: UInt32
        if value.isFinite, abs(value) <= maximum {
            // +180 and -180 denote the same meridian; +180 does not fit in signed semicircles.
            let normalized = value == 180 ? -180 : value
            let semicircles = (normalized * 2147483648 / 180).rounded()
            // Rounding a longitude immediately below +180 can reach the reserved invalid value
            // or overflow Int32. Keep finite, valid coordinates representable.
            raw = UInt32(bitPattern: Int32(min(2147483646, max(-2147483648, semicircles))))
        } else { raw = 0x7fffffff }
        return Field(number: number, type: 0x85, bytes: be(raw))
    }

    private static func float(_ number: UInt8, _ value: Double?) -> Field {
        let raw: UInt32
        if let value, value.isFinite, value >= 0, value <= Double(Float.greatestFiniteMagnitude) { raw = Float(value).bitPattern }
        else { raw = UInt32.max }
        return Field(number: number, type: 0x88, bytes: be(raw))
    }

    private static func string(_ number: UInt8, _ value: String) -> Field {
        var bytes: [UInt8] = []
        for scalar in value.unicodeScalars where scalar.value != 0 {
            let next = Array(String(scalar).utf8)
            guard bytes.count + next.count <= 63 else { break }
            bytes += next
        }
        return Field(number: number, type: 7, bytes: bytes + [0])
    }
}

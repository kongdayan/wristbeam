import Foundation

// Compiled by both the main app and the WidgetKit extension. No cloud session,
// account identity, Bluetooth API or FIT file is part of this shared schema.
struct PulseWidgetPoint: Codable, Equatable {
    let seconds: Double
    let value: Double
    var endSeconds: Double? = nil
}

struct PulseWidgetReading: Codable, Equatable, Identifiable {
    let id: String
    let title: String
    let symbol: String
    let value: String
    let unit: String
    let source: String
    let updatedAt: Date?
    let stale: Bool
    let category: String
    let segments: [[PulseWidgetPoint]]
    let lowerBound: Double
    let upperBound: Double
    var style = "line"
}

struct PulseWidgetSnapshot: Codable, Equatable {
    var schemaVersion = 1
    let generatedAt: Date
    let day: Date
    let regionTitle: String
    let watchConnected: Bool
    let readings: [PulseWidgetReading]
    var appearance = "system"
    static var empty: Self { Self(generatedAt: Date(), day: Calendar.current.startOfDay(for: Date()), regionTitle: "WristBeam", watchConnected: false, readings: []) }
    static let fileName = "widget-snapshot.json"
    static let widgetKind = "GarminPulseHealthWidget"
    static let groupInfoKey = "GarminPulseWidgetAppGroup"

    static func decode(_ bytes: Data) throws -> Self {
        guard bytes.count <= 8 * 1024 * 1024 else { throw CocoaError(.fileReadCorruptFile) }
        let result = try JSONDecoder().decode(Self.self, from: bytes)
        guard result.schemaVersion == 1, result.readings.count <= 64,
              result.readings.allSatisfy({ $0.id.count <= 100 && $0.title.count <= 120 && $0.segments.flatMap { $0 }.count <= 2000 && $0.lowerBound.isFinite && $0.upperBound.isFinite && $0.upperBound > $0.lowerBound && $0.segments.flatMap { $0 }.allSatisfy { $0.seconds.isFinite && (0...90000).contains($0.seconds) && $0.value.isFinite } }) else { throw CocoaError(.fileReadCorruptFile) }
        return result
    }
}

enum PulseWidgetLink {
    static func url(metricID: String, day: Date) -> URL {
        var parts = URLComponents()
        parts.scheme = "garminpulse"; parts.host = "metric"; parts.path = "/" + metricID
        let formatter = DateFormatter(); formatter.locale = Locale(identifier: "en_US_POSIX"); formatter.dateFormat = "yyyy-MM-dd"
        parts.queryItems = [URLQueryItem(name: "date", value: formatter.string(from: day))]
        return parts.url!
    }
    static func destination(_ url: URL) -> (metricID: String, day: Date?)? {
        guard url.scheme == "garminpulse", url.host == "metric", url.user == nil, url.password == nil, url.port == nil, url.fragment == nil,
              url.path.split(separator: "/").count == 1,
              let parts = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
        let query = parts.queryItems ?? []
        guard query.count <= 1, query.allSatisfy({ $0.name == "date" }) else { return nil }
        let id = String(url.path.dropFirst())
        guard id.range(of: "^[A-Za-z][A-Za-z0-9.]*$", options: .regularExpression) != nil, id.count <= 100 else { return nil }
        var day: Date?
        if let item = query.first {
            let formatter = DateFormatter(); formatter.locale = Locale(identifier: "en_US_POSIX"); formatter.dateFormat = "yyyy-MM-dd"; formatter.isLenient = false
            guard let value = item.value, let date = formatter.date(from: value), formatter.string(from: date) == value,
                  date <= Date() else { return nil }
            day = date
        }
        return (id, day)
    }
}

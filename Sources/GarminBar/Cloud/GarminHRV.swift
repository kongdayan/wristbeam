import Foundation
import CoreFoundation
import CryptoKit

extension MetricKind {
    static let hrvNight = Self(rawValue: "hrv.lastNight")!
    static let hrvWeekly = Self(rawValue: "hrv.weeklyAverage")!
    static let hrvStatus = Self(rawValue: "hrv.status")!
    static let hrvHigh = Self(rawValue: "hrv.lastNightHigh")!
    var isOvernightHRV: Bool { rawValue.hasPrefix("hrv.") }
}

enum GarminHRVStatus: Int, Codable, CaseIterable {
    case none, balanced, invalid, low, poor, unbalanced, unbalancedLow, unbalancedUpper
    init?(wire: String) {
        switch wire {
        case "NONE", "NO_STATUS": self = .none
        case "BALANCED": self = .balanced
        case "INVALID": self = .invalid
        case "LOW": self = .low
        case "POOR": self = .poor
        case "UNBALANCED": self = .unbalanced
        case "UNBALANCED_LOW": self = .unbalancedLow
        case "UNBALANCED_UPPER": self = .unbalancedUpper
        default: return nil
        }
    }
    var title: String {
        switch self {
        case .none: return L10n.text("暂无状态")
        case .balanced: return L10n.text("平衡")
        case .invalid: return L10n.text("数据不足")
        case .low: return L10n.text("偏低")
        case .poor: return L10n.text("较差")
        case .unbalanced: return L10n.text("不平衡")
        case .unbalancedLow: return L10n.text("不平衡（偏低）")
        case .unbalancedUpper: return L10n.text("不平衡（偏高）")
        }
    }
}

struct GarminHRVSummary: Codable, Equatable, Identifiable {
    let day: Date
    var night: Double?
    var weekly: Double?
    var high: Double?
    var baselineLow: Double?
    var baselineHigh: Double?
    var status: GarminHRVStatus?
    var id: Date { day }
    func value(for kind: MetricKind) -> Double? {
        switch kind { case .hrvNight: return night; case .hrvWeekly: return weekly; case .hrvHigh: return high; case .hrvStatus: return status.map { Double($0.rawValue) }; default: return nil }
    }
    var hasMeasurements: Bool { night != nil || weekly != nil || high != nil }
}

struct GarminHRVReport: Codable, Equatable {
    var summaries: [GarminHRVSummary]
    var nights: [String: [MetricSeriesPoint]]
    var refreshedAt: Date
    var nightWarning: String? = nil
    var latest: GarminHRVSummary? { summaries.last(where: \.hasMeasurements) }
    var samples: [MetricSample] {
        guard let latest else { return [] }
        return [.hrvNight, .hrvWeekly, .hrvHigh, .hrvStatus].compactMap { kind in
            latest.value(for: kind).map { MetricSample(kind: kind, value: $0, source: "佳明云 · 夜间 HRV", timestamp: latest.day, origin: .cloud) }
        }
    }
    func trend(_ kind: MetricKind) -> MetricDaySeries? {
        guard kind != .hrvStatus, let first = summaries.first else { return nil }
        return MetricDaySeries(kind: kind, day: first.day, points: summaries.map { MetricSeriesPoint(timestamp: $0.day, value: $0.value(for: kind)) }, source: "佳明云 · 夜间 HRV", refreshedAt: refreshedAt)
    }
}

enum GarminHRV {
    static func date(_ text: String) -> Date? {
        let formatter = DateFormatter(); formatter.locale = Locale(identifier: "en_US_POSIX"); formatter.dateFormat = "yyyy-MM-dd"; formatter.isLenient = false
        guard let date = formatter.date(from: text), formatter.string(from: date) == text else { return nil }; return date
    }
    static func number(_ value: Any?) -> Double? {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(), number.doubleValue.isFinite, number.doubleValue > 0 else { return nil }
        return number.doubleValue
    }
    static func summary(_ object: [String: Any], now: Date = Date()) -> GarminHRVSummary? {
        guard let text = object["calendarDate"] as? String, let day = date(text), day <= now else { return nil }
        let baseline = object["baseline"] as? [String: Any] ?? [:]
        let low = number(baseline["balancedLow"]), high = number(baseline["balancedUpper"])
        let validBaseline = low != nil && high != nil && low! <= high!
        return GarminHRVSummary(day: day, night: number(object["lastNightAvg"]), weekly: number(object["weeklyAvg"]), high: number(object["lastNight5MinHigh"]), baselineLow: validBaseline ? low : nil, baselineHigh: validBaseline ? high : nil, status: (object["status"] as? String).flatMap(GarminHRVStatus.init(wire:)))
    }
    static func history(_ data: Data, now: Date = Date()) throws -> [GarminHRVSummary] {
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any], let rows = object["hrvSummaries"] as? [[String: Any]] else { throw GarminCloudError.invalidResponse("HRV 历史格式不正确") }
        var days: [Date: GarminHRVSummary] = [:]
        for row in rows { if let item = summary(row, now: now) { days[item.day] = item } }
        return days.values.sorted { $0.day < $1.day }
    }
    static func night(_ data: Data, expectedDay: Date, now: Date = Date()) throws -> (GarminHRVSummary?, [MetricSeriesPoint]) {
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any], let raw = object["hrvSummary"] as? [String: Any], let item = summary(raw, now: now), Calendar.current.isDate(item.day, inSameDayAs: expectedDay) else { throw GarminCloudError.invalidResponse("HRV 夜间日期不匹配") }
        let lower = Calendar.current.date(byAdding: .day, value: -1, to: item.day)!
        let upper = Calendar.current.date(byAdding: .day, value: 1, to: item.day)!
        var points: [Date: MetricSeriesPoint] = [:]
        for reading in object["hrvReadings"] as? [[String: Any]] ?? [] {
            guard let stamp = reading["readingTimeGMT"] as? String, let time = GarminHealthMetrics.gmtDate(stamp), time >= lower, time < upper, time <= now else { continue }
            points[time] = MetricSeriesPoint(timestamp: time, value: number(reading["hrvValue"]), origin: .cloud)
        }
        return (item, points.values.sorted { $0.timestamp < $1.timestamp })
    }
}

final class GarminHRVStore {
    private let file: URL
    init(file: URL) { self.file = file }
    init(owner: String, root: URL = AppPaths.directory("HRV")) {
        let hash = SHA256.hash(data: Data(owner.utf8)).map { String(format: "%02x", $0) }.joined()
        file = root.appendingPathComponent(hash + ".json")
    }
    func load() -> GarminHRVReport? { guard let data = try? Data(contentsOf: file) else { return nil }; return try? JSONDecoder().decode(GarminHRVReport.self, from: data) }
    func save(_ report: GarminHRVReport) { if let data = try? JSONEncoder().encode(report) { try? GarminPrivateFile.write(data, to: file) } }
}

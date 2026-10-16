import Foundation
import CryptoKit
import CoreFoundation

struct MetricSeriesPoint: Codable, Equatable, Identifiable {
    var timestamp: Date
    var value: Double?
    var end: Date? = nil
    var origin: MetricOrigin = .cloud
    var charging: Bool? = nil
    var unavailable: String? = nil
    var label: String? = nil
    var id: Date { timestamp }
}

struct MetricDaySeries: Codable, Equatable {
    let kind: MetricKind
    let day: Date
    var points: [MetricSeriesPoint]
    var source: String
    var refreshedAt: Date

    var values: [MetricSeriesPoint] { points.filter { $0.value != nil } }
    var latest: MetricSeriesPoint? { values.last }
    var maximum: Double? { values.compactMap(\.value).max() }
    var minimum: Double? { values.compactMap(\.value).min() }
    var mean: Double? { let v = values.compactMap(\.value); return v.isEmpty ? nil : v.reduce(0, +) / Double(v.count) }
    var total: Double? { let v = values.compactMap(\.value); return v.isEmpty ? nil : v.reduce(0, +) }
    var gapLimit: TimeInterval {
        switch kind.rawValue {
        case "solarIntensity": return 150
        case "heartRate", "respiration": return 300
        case "stress", "bodyBattery": return 420
        case "spo2": return 5400
        default: return 150
        }
    }
    // Segments retain explicit missing readings and sampling gaps. A line never
    // bridges a long period with no observations, or fills the rest of the day.
    var segments: [[MetricSeriesPoint]] {
        var result: [[MetricSeriesPoint]] = [], current: [MetricSeriesPoint] = []
        for point in points {
            guard point.value != nil else {
                if !current.isEmpty { result.append(current); current = [] }; continue
            }
            if let previous = current.last, point.timestamp.timeIntervalSince(previous.timestamp) > gapLimit || point.label != previous.label {
                result.append(current); current = []
            }
            current.append(point)
        }
        if !current.isEmpty { result.append(current) }
        return result
    }
    func nearest(to date: Date) -> MetricSeriesPoint? {
        guard !points.isEmpty else { return nil }
        var lower = 0, upper = points.count
        while lower < upper {
            let middle = (lower + upper) / 2
            if points[middle].timestamp < date { lower = middle + 1 } else { upper = middle }
        }
        if lower == 0 { return points[0] }
        if lower == points.count { return points[lower - 1] }
        let previous = points[lower - 1], next = points[lower]
        return abs(previous.timestamp.timeIntervalSince(date)) <= abs(next.timestamp.timeIntervalSince(date)) ? previous : next
    }
    func reading(at date: Date) -> MetricSeriesPoint? {
        if kind.seriesStyle == .bars, kind != .stress {
            if let interval = points.first(where: { $0.timestamp <= date && $0.end.map { date < $0 } == true }) { return interval }
        }
        guard let point = nearest(to: date), abs(point.timestamp.timeIntervalSince(date)) <= gapLimit / 2 else { return nil }
        return point
    }
    func merging(_ incoming: MetricDaySeries) -> MetricDaySeries {
        guard incoming.kind == kind, Calendar.current.isDate(incoming.day, inSameDayAs: day) else { return self }
        var minutes: [Int: MetricSeriesPoint] = [:]
        for point in points + incoming.points {
            let key = Int(point.timestamp.timeIntervalSince1970 / 60)
            if let existing = minutes[key] {
                if existing.origin == .watch && point.origin != .watch { continue }
                if existing.value != nil && point.value == nil { continue }
                if existing.origin == point.origin && existing.timestamp > point.timestamp { continue }
            }
            minutes[key] = point
        }
        var result = self
        result.points = minutes.values.sorted { $0.timestamp < $1.timestamp }
        result.refreshedAt = max(refreshedAt, incoming.refreshedAt)
        if incoming.source.contains("佳明") { result.source = incoming.source }
        return result
    }
}

enum MetricSeriesStyle { case line, area, bars }

extension MetricKind {
    static var dailyTimelineMetrics: [MetricKind] { [solarIntensity, heartRate, stress, bodyBattery, steps] + ["respiration", "spo2", "floors"].compactMap(Self.init(rawValue:)) }
    var timelineKind: MetricKind? {
        if isDeviceStatus { return nil }
        if group == .live { return self }
        if group == .solar { return .solarIntensity }
        let key = definition.dailyKey ?? ""
        if key.hasPrefix("bodyBattery") { return .bodyBattery }
        if key.localizedCaseInsensitiveContains("stress") { return .stress }
        if key.localizedCaseInsensitiveContains("respiration") { return Self(rawValue: "respiration") }
        if key.localizedCaseInsensitiveContains("spo2") { return Self(rawValue: "spo2") }
        if key == "floorsDescended" { return self }
        if ["minHeartRate", "maxHeartRate"].contains(key) { return .heartRate }
        return nil
    }
    var seriesStyle: MetricSeriesStyle {
        if ["stress", "steps", "floors", "pushes", "daily.floorsDescended"].contains(rawValue) { return .bars }
        if ["solarIntensity", "bodyBattery"].contains(rawValue) { return .area }
        return .line
    }
    var acceptsLiveTimeline: Bool {
        // These live counters are cumulative. Their cloud charts contain interval
        // increments, so putting a live total into a bar would corrupt the chart.
        group == .live && !isDeviceStatus && !["steps", "floors", "pushes"].contains(rawValue)
    }
    var seriesUnit: String { ["stress", "bodyBattery", "trainingReadiness"].contains(rawValue) ? L10n.text("点") : unit }
    var seriesExplanation: String {
        switch rawValue {
        case "solarIntensity": return "光照强度是太阳能利用率（0–100%），并非直接测得的 lux。充电状态来自同一条分钟记录。日照时长按所选阈值估算，不能区分室内灯光与户外阳光。"
        case "bodyBattery": return "身体电量按 0–100 绘制，可叠加同期压力：蓝色为休息，橙色为压力。空白表示没有可用的身体电量读数。"
        case "stress": return "蓝色为休息（0–25），黄色为低压力（26–50），橙色为中压力（51–75），红色为高压力（76–100）。灰色标记不可测，不能当成零压力。"
        case "steps", "pushes", "floors", "daily.floorsDescended": return "柱形表示该时间段内的新增数量；上方读数是全天累计。时间段来自原始记录，没有记录的时段不会补零。"
        case "hrv": return "这是心搏间期（RR），单位毫秒，不是夜间 HRV 分数。图中仅包含 Mac 实际接收到的读数，每分钟保留最近一次；未连接期间留空。"
        case "heartRate", "respiration", "spo2": return "按实际采样时间显示佳明云已同步记录及 Mac 接收的读数。血氧记录会区分连续测量、单次测量和小时均值；缺测与未同步时段留空。"
        default: return "该指标的曲线仅包含 Mac 实际接收到的读数，每分钟保留最近一次。未连接期间留空；全天累计值不等于每个时刻的增量。"
        }
    }
}

struct GarminSeriesRefresh {
    var series: [MetricKind: MetricDaySeries] = [:]
    var notes: [MetricKind: String] = [:]
    var detail = ""
}

// Cache is scoped to the authenticated account. Only health readings go here;
// credentials stay in the existing authentication store.
final class MetricSeriesStore {
    private let directory: URL
    private let lock = NSLock()
    private var writtenRevisions: [String: UInt64] = [:]
    init(directory: URL) { self.directory = directory }
    init(accountGUID: String, root: URL = AppPaths.directory("Charts")) {
        let digest = SHA256.hash(data: Data(accountGUID.utf8)).map { String(format: "%02x", $0) }.joined()
        directory = root.appendingPathComponent(digest, isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    }
    private struct Envelope: Codable {
        var schemaVersion = 1
        var series: [MetricDaySeries]
    }
    func loadChecked(day: Date) throws -> [MetricKind: MetricDaySeries] {
        let url = file(day)
        guard FileManager.default.fileExists(atPath: url.path) else { return [:] }
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        let data = try Data(contentsOf: url)
        let series: [MetricDaySeries]
        if let legacy = try? decoder.decode([MetricDaySeries].self, from: data) { series = legacy }
        else {
            let envelope = try decoder.decode(Envelope.self, from: data)
            guard envelope.schemaVersion == 1 else { throw CocoaError(.fileReadCorruptFile) }
            series = envelope.series
        }
        return Dictionary(series.filter { Calendar.current.isDate($0.day, inSameDayAs: day) }.map { ($0.kind, $0) }, uniquingKeysWith: { _, new in new })
    }
    func load(day: Date) -> [MetricKind: MetricDaySeries] { (try? loadChecked(day: day)) ?? [:] }
    func saveChecked(_ series: [MetricKind: MetricDaySeries], day: Date, revision: UInt64 = 0) throws {
        lock.lock(); defer { lock.unlock() }
        let key = GarminHealthMetrics.calendarDate(day)
        guard revision >= (writtenRevisions[key] ?? 0) else { return }
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        try GarminPrivateFile.write(encoder.encode(Envelope(series: Array(series.values))), to: file(day))
        writtenRevisions[key] = revision
    }
    func save(_ series: [MetricKind: MetricDaySeries], day: Date) { try? saveChecked(series, day: day) }
    private func file(_ day: Date) -> URL { directory.appendingPathComponent(GarminHealthMetrics.calendarDate(day) + ".json") }
    static func localReadings(day: Date, now: Date = Date()) -> [MetricKind: MetricDaySeries] {
        HealthHistoryReader(telemetry: AppPaths.directory("Telemetry")).read(day: day, now: now).series
    }
}

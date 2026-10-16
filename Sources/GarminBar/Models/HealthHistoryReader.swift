import Foundation
import CoreFoundation

struct HealthHistoryResult {
    var series: [MetricKind: MetricDaySeries] = [:]
    var issues: [String] = []
}

/// The same local-only query is used by UI, export and developer clients.
/// Call on a utility task; it never performs networking or changes account state.
struct HealthHistoryReader {
    let telemetry: URL
    var charts: MetricSeriesStore?
    var legacyCharts: MetricSeriesStore?

    func read(day: Date, now: Date = Date()) -> HealthHistoryResult {
        var result = HealthHistoryResult()
        do {
            result.series = try charts?.loadChecked(day: day) ?? [:]
            if result.series.isEmpty { result.series = try legacyCharts?.loadChecked(day: day) ?? [:] }
        }
        catch { result.issues.append("chartReadFailed") }
        let file = telemetry.appendingPathComponent(GarminHealthMetrics.calendarDate(day) + ".jsonl")
        guard FileManager.default.fileExists(atPath: file.path) else { return result }
        var minutes: [MetricKind: [Int: MetricSeriesPoint]] = [:]
        do {
            try Self.samples(file: file, onInvalid: { result.issues.append("invalidTelemetryRecord") }) { sample in
                guard sample.kind.acceptsLiveTimeline, Calendar.current.isDate(sample.timestamp, inSameDayAs: day), sample.timestamp <= now else { return }
                let key = Int(sample.timestamp.timeIntervalSince1970 / 60)
                if minutes[sample.kind]?[key]?.timestamp ?? .distantPast <= sample.timestamp {
                    minutes[sample.kind, default: [:]][key] = .init(timestamp: sample.timestamp, value: sample.value, origin: .watch)
                }
            }
        } catch { result.issues.append("telemetryReadFailed") }
        for (kind, points) in minutes {
            let local = MetricDaySeries(kind: kind, day: Calendar.current.startOfDay(for: day),
                points: points.values.sorted { $0.timestamp < $1.timestamp }, source: "Mac 接收的手表读数 · 每分钟最近一次",
                refreshedAt: points.values.map(\.timestamp).max() ?? day)
            result.series[kind] = result.series[kind].map { $0.merging(local) } ?? local
        }
        result.issues = Array(Set(result.issues)).sorted()
        return result
    }

    /// Streaming parser shared with original-resolution CSV export. A truncated last
    /// record is reported, while earlier valid records remain readable.
    static func samples(file: URL, onInvalid: () -> Void = {}, body: (MetricSample) throws -> Void) throws {
        guard file.standardizedFileURL == file.resolvingSymlinksInPath().standardizedFileURL else { throw CocoaError(.fileReadNoPermission) }
        let reader = try FileHandle(forReadingFrom: file)
        defer { try? reader.close() }
        func consume(_ line: Data) throws {
            guard !line.isEmpty else { return }
            guard let object = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any] else { onInvalid(); return }
            guard (object["origin"] as? String ?? "watch") == "watch" else { return }
            guard let raw = object["kind"] as? String, let kind = MetricKind(rawValue: raw),
                  let stamp = object["timestamp"] as? String, let date = GarminHealthMetrics.gmtDate(stamp),
                  let value = object["value"] as? NSNumber, CFGetTypeID(value) != CFBooleanGetTypeID(), value.doubleValue.isFinite else { onInvalid(); return }
            guard !kind.isDeviceStatus else { return }
            try body(.init(kind: kind, value: value.doubleValue, source: "watch", timestamp: date, origin: .watch))
        }
        var pending = Data()
        while let chunk = try reader.read(upToCount: 65_536), !chunk.isEmpty {
            pending.append(chunk)
            while let end = pending.firstIndex(of: 10) {
                try consume(pending.subdata(in: pending.startIndex..<end))
                pending.removeSubrange(pending.startIndex...end)
            }
            guard pending.count < 1_000_000 else { throw CocoaError(.fileReadCorruptFile) }
        }
        if !pending.isEmpty { try consume(pending) }
    }
}

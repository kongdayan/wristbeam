import Foundation
import CoreFoundation

struct HealthHistoryResult {
    var series: [MetricKind: MetricDaySeries] = [:]
    var issues: [String] = []
    var usedIndex = false
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
        let signature = try? Self.signature(file)
        let indexURL = telemetry.appendingPathComponent("Index").appendingPathComponent(GarminHealthMetrics.calendarDate(day) + ".json")
        let cached = (try? Data(contentsOf: indexURL)).flatMap { try? JSONDecoder().decode(DayIndex.self, from: $0) }
        let localSeries: [MetricDaySeries]
        if let cached, cached.schemaVersion == 1, cached.signature == signature, cached.timeZone == TimeZone.current.identifier, cached.day == Calendar.current.startOfDay(for: day) {
            localSeries = cached.series; result.issues += cached.issues; result.usedIndex = true
        } else {
            var minutes: [MetricKind: [Int: MetricSeriesPoint]] = [:]
            var issues: [String] = []
            do {
                try Self.samples(file: file, onInvalid: { if !issues.contains("invalidTelemetryRecord") { issues.append("invalidTelemetryRecord") } }) { sample in
                    guard sample.kind.acceptsLiveTimeline, Calendar.current.isDate(sample.timestamp, inSameDayAs: day) else { return }
                    let key = Int(sample.timestamp.timeIntervalSince1970 / 60)
                    if minutes[sample.kind]?[key]?.timestamp ?? .distantPast <= sample.timestamp {
                        minutes[sample.kind, default: [:]][key] = .init(timestamp: sample.timestamp, value: sample.value, origin: .watch)
                    }
                }
            } catch { issues.append("telemetryReadFailed") }
            localSeries = minutes.map { kind, points in
                MetricDaySeries(kind: kind, day: Calendar.current.startOfDay(for: day),
                    points: points.values.sorted { $0.timestamp < $1.timestamp }, source: "Mac 接收的手表读数 · 每分钟最近一次",
                    refreshedAt: points.values.map(\.timestamp).max() ?? day)
            }
            result.issues += issues
            // Only completed historical days are indexed: the active journal changes
            // every second and would otherwise create continuous index writes.
            if !Calendar.current.isDate(day, inSameDayAs: now), let signature,
               signature == (try? Self.signature(file)), !issues.contains("telemetryReadFailed") {
                do { try GarminPrivateFile.write(JSONEncoder().encode(DayIndex(signature: signature, timeZone: TimeZone.current.identifier, day: Calendar.current.startOfDay(for: day), series: localSeries, issues: issues)), to: indexURL) }
                catch { result.issues.append("historyIndexWriteFailed") }
            }
        }
        for var local in localSeries {
            local.points.removeAll { $0.timestamp > now }
            result.series[local.kind] = result.series[local.kind].map { $0.merging(local) } ?? local
        }
        result.issues = Array(Set(result.issues)).sorted()
        return result
    }

    private struct FileSignature: Codable, Equatable {
        var bytes: UInt64
        var modified: Date
        var inode: UInt64
    }
    private struct DayIndex: Codable {
        var schemaVersion = 1
        var signature: FileSignature
        var timeZone: String
        var day: Date
        var series: [MetricDaySeries]
        var issues: [String]
    }
    private static func signature(_ file: URL) throws -> FileSignature {
        let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
        guard attributes[.type] as? FileAttributeType == .typeRegular,
              let modified = attributes[.modificationDate] as? Date,
              let bytes = attributes[.size] as? NSNumber, let inode = attributes[.systemFileNumber] as? NSNumber else { throw CocoaError(.fileReadCorruptFile) }
        return FileSignature(bytes: bytes.uint64Value, modified: modified, inode: inode.uint64Value)
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

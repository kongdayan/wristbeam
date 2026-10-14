import Foundation

struct DashboardShareRequest: Identifiable {
    let id = UUID()
    let kinds: [MetricKind]
    var valueOnly = false
}

// Explicit allowlist: no account, device identifiers, credentials, paths or raw
// source strings cross the rendering boundary. Values are frozen on opening.
struct SharedMetric: Identifiable {
    let kind: MetricKind
    let value: String
    let updatedAt: Date?
    let unavailable: Bool
    let series: MetricDaySeries?
    var id: String { kind.rawValue }
}

enum DashboardSharing {
    static let basicMetrics: Set<MetricKind> = [.heartRate, .bodyBattery, .stress, .steps, .solarIntensity, .sunlightMinutes, .hrvNight, .hrvWeekly, .hrvStatus, .watchBattery, MetricKind(rawValue: "hrv")!]
    static func selected(_ metrics: [SharedMetric], ids: Set<MetricKind>, valueOnly: Bool) -> [SharedMetric] {
        var seen: Set<MetricKind> = []
        let chosen = metrics.filter { ids.contains($0.kind) && seen.insert($0.kind).inserted }
        return valueOnly ? Array(chosen.prefix(1)).map {
            SharedMetric(kind: $0.kind, value: $0.value, updatedAt: $0.updatedAt, unavailable: $0.unavailable, series: nil)
        } : chosen
    }
    static func sanitizedSeries(_ series: MetricDaySeries?) -> MetricDaySeries? {
        guard let series else { return nil }
        return MetricDaySeries(kind: series.kind, day: series.day, points: series.points.map {
            MetricSeriesPoint(timestamp: $0.timestamp, value: $0.value, end: $0.end, origin: $0.origin, charging: $0.charging)
        }, source: "", refreshedAt: series.refreshedAt)
    }
}

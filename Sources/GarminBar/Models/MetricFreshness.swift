import Foundation

/// Valid historical measurements and current-state readings are different things.
/// All consumers use this policy; transport success never makes an old sample fresh.
struct MetricFreshness: Equatable {
    let recordedAt: Date
    let syncedAt: Date?
    let ageSeconds: TimeInterval
    let stale: Bool
    let suitableForCurrentState: Bool
    let temporalKind: String

    static func evaluate(_ sample: MetricSample, now: Date, connected: Bool, syncedAt: Date? = nil) -> Self {
        let age = max(0, now.timeIntervalSince(sample.timestamp))
        let future = sample.timestamp.timeIntervalSince(now) > 60
        let sameDay = Calendar.current.isDate(sample.timestamp, inSameDayAs: now)
        let overnight = sample.kind.isOvernightHRV
        let daily = sample.timestampIsMeasurement == false || sample.kind.group == .daily || sample.kind.group == .solar && sample.kind != .solarIntensity ||
            ["steps", "calories", "floors", "intensityMinutes", "activeTime", "pushes"].contains(sample.kind.rawValue)
        let stale: Bool
        if overnight {
            // Yesterday's night remains useful until the next nightly record is due.
            let days = Calendar.current.dateComponents([.day], from: Calendar.current.startOfDay(for: sample.timestamp),
                                                       to: Calendar.current.startOfDay(for: now)).day ?? 0
            stale = future || days > 1
        } else if daily { stale = future || !sameDay }
        else { stale = future || age > sample.kind.definition.freshness || (sample.origin == .watch && !connected) }
        return Self(recordedAt: sample.timestamp, syncedAt: syncedAt, ageSeconds: age, stale: stale,
                    suitableForCurrentState: !stale && !overnight && !daily,
                    temporalKind: overnight ? "overnight" : daily ? "dailyAggregate" : "instant")
    }
}

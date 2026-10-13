import Foundation
import CoreFoundation

struct GarminHealthRefresh {
    var samples: [MetricSample] = []
    var notes: [MetricKind: String] = [:]
    var detail = ""
    var solarSeries: MetricDaySeries? = nil
}

enum GarminHealthMetrics {
    static func calendarDate(_ date: Date) -> String {
        let formatter = DateFormatter(); formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"; return formatter.string(from: date)
    }

    static func daily(_ data: Data, now: Date = Date()) throws -> [MetricSample] {
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw GarminCloudError.invalidResponse("今日汇总格式不正确") }
        guard object["calendarDate"] as? String == calendarDate(now) else { return [] }
        var samples: [MetricSample] = []
        for kind in MetricKind.allCases {
            guard let key = kind.definition.dailyKey, let number = object[key] as? NSNumber,
                  CFGetTypeID(number) != CFBooleanGetTypeID() else { continue }
            let value = number.doubleValue
            guard value.isFinite, value >= 0 || key == "netRemainingKilocalories" else { continue }
            if key.localizedCaseInsensitiveContains("HeartRate"), value <= 0 || value >= 400 { continue }
            if key.localizedCaseInsensitiveContains("Spo2"), value <= 0 || value > 100 { continue }
            if key.hasPrefix("bodyBattery"), value > 100 { continue }
            samples.append(MetricSample(kind: kind, value: value * kind.definition.scale, source: "佳明中国 · 今日已同步", timestamp: now, origin: .cloud))
        }
        if let moderate = object["moderateIntensityMinutes"] as? NSNumber, let vigorous = object["vigorousIntensityMinutes"] as? NSNumber,
           moderate.doubleValue >= 0, vigorous.doubleValue >= 0, let kind = MetricKind(rawValue: "intensityMinutes") {
            samples.append(MetricSample(kind: kind, value: moderate.doubleValue + 2 * vigorous.doubleValue, source: "佳明中国 · 今日已同步", timestamp: now, origin: .cloud))
        }
        return samples
    }

    // APK in1/a and jn1/{c,d,e,f}: one-minute solarInputReadings, percentage 0...100.
    // A light threshold is an explicit estimate; it does not identify outdoor exposure.
    static func solar(_ data: Data, threshold: Double = 20, now: Date = Date()) throws -> [MetricSample] {
        let series = try solarTimeline(data, day: now, now: now)
        return solarSamples(series, threshold: threshold)
    }

    static func solarSamples(_ series: MetricDaySeries, threshold: Double = 20) -> [MetricSample] {
        guard let latest = series.latest, let value = latest.value else { return [] }
        let cutoff = min(100, max(0, threshold))
        let sunlight = series.values.filter { ($0.value ?? 0) >= cutoff && ($0.value ?? 0) > 0 }.count
        let charging = series.values.filter { $0.charging == true && ($0.value ?? 0) > 0 }.count
        return [
            MetricSample(kind: .solarIntensity, value: value, source: "佳明中国 · 最近光照记录", timestamp: latest.timestamp, origin: .cloud),
            MetricSample(kind: .sunlightMinutes, value: sunlight, source: "佳明中国 · 今日强度 ≥ \(Int(cutoff))% 的分钟记录（估算）", timestamp: latest.timestamp, origin: .estimated),
            MetricSample(kind: .solarChargingMinutes, value: charging, source: "佳明中国 · 今日有太阳能输入且充电的分钟记录（估算）", timestamp: latest.timestamp, origin: .estimated)
        ]
    }

    static func solarTimeline(_ data: Data, day target: Date, now: Date = Date()) throws -> MetricDaySeries {
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw GarminCloudError.invalidResponse("太阳能记录格式不正确") }
        let solar = object["deviceSolarInput"] as? [String: Any]
        let days = solar?["solarDailyDataDTOs"] as? [[String: Any]] ?? []
        var minutes: [Int: MetricSeriesPoint] = [:]
        for day in days where day["localConnectDate"] as? String == calendarDate(target) {
            for point in day["solarInputReadings"] as? [[String: Any]] ?? [] {
                guard point["interpolated"] as? Bool != true,
                      let number = point["solarUtilization"] as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
                      let text = point["readingTimestampGmt"] as? String, let date = gmtDate(text),
                      date <= now, Calendar.current.isDate(date, inSameDayAs: target) else { continue }
                let value = number.doubleValue
                guard value.isFinite, (0...100).contains(value) else { continue }
                let minute = Int(date.timeIntervalSince1970 / 60)
                let candidate = MetricSeriesPoint(timestamp: date, value: value, charging: point["charging"] as? Bool)
                if minutes[minute]?.timestamp ?? .distantPast <= date { minutes[minute] = candidate }
            }
        }
        return MetricDaySeries(kind: .solarIntensity, day: Calendar.current.startOfDay(for: target), points: minutes.values.sorted { $0.timestamp < $1.timestamp }, source: "佳明中国 · 分钟光照记录", refreshedAt: now)
    }

    static func gmtDate(_ value: String) -> Date? {
        let formatter = ISO8601DateFormatter(); formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let text = value.hasSuffix("Z") || value.range(of: #"[+-]\d\d:\d\d$"#, options: .regularExpression) != nil ? value : value + "Z"
        if let date = formatter.date(from: text) { return date }
        formatter.formatOptions = [.withInternetDateTime]; return formatter.date(from: text)
    }
}

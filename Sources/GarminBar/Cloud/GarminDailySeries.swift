import Foundation
import CoreFoundation

enum GarminSeriesEndpoint: String, CaseIterable {
    case heartRate, stress, bodyBattery, steps, respiration, spo2, floors
    var kinds: [MetricKind] {
        switch self {
        case .stress: return [.stress, .bodyBattery]
        case .floors: return [MetricKind(rawValue: "floors")!, MetricKind(rawValue: "daily.floorsDescended")!]
        case .steps: return [.steps, MetricKind(rawValue: "pushes")!]
        default: return [MetricKind(rawValue: rawValue)!]
        }
    }
    func url(day: Date, profile: String, region: GarminRegion = .china) -> URL {
        let date = GarminHealthMetrics.calendarDate(day)
        var parts = URLComponents(string: region.apiBase)!
        switch self {
        case .heartRate:
            parts.path = "/wellness-service/wellness/dailyHeartRate/\(profile)"
            parts.queryItems = [URLQueryItem(name: "date", value: date)]
        case .stress: parts.path = "/wellness-service/wellness/dailyStress/\(date)"
        case .bodyBattery:
            parts.path = "/wellness-service/wellness/bodyBattery/reports/daily"
            parts.queryItems = [URLQueryItem(name: "startDate", value: date), URLQueryItem(name: "endDate", value: date)]
        case .steps:
            parts.path = "/wellness-service/wellness/dailySummaryChart/\(profile)"
            parts.queryItems = [URLQueryItem(name: "date", value: date)]
        case .respiration: parts.path = "/wellness-service/wellness/daily/respiration/\(date)"
        case .spo2: parts.path = "/wellness-service/wellness/daily/spo2/\(date)"
        case .floors: parts.path = "/wellness-service/wellness/floorsChartData/daily/\(date)"
        }
        return parts.url!
    }
}

enum GarminDailySeries {
    // Endpoint and descriptor shapes were verified against the signed-in China
    // account. Descriptor indices, GMT timestamps and missing values are retained.
    static func parse(_ data: Data, endpoint: GarminSeriesEndpoint, day: Date, now: Date = Date()) throws -> [MetricKind: MetricDaySeries] {
        let root = try JSONSerialization.jsonObject(with: data)
        let date = GarminHealthMetrics.calendarDate(day)
        var object = root as? [String: Any] ?? [:]
        if endpoint == .bodyBattery {
            object = (root as? [[String: Any]])?.first { $0["date"] as? String == date } ?? [:]
        }
        if let returned = object["calendarDate"] as? String, returned != date { return [:] }
        var result: [MetricKind: MetricDaySeries] = [:]
        func add(_ kind: MetricKind, _ points: [MetricSeriesPoint], _ source: String = "佳明中国 · 全天已同步记录") {
            let series = MetricDaySeries(kind: kind, day: Calendar.current.startOfDay(for: day), points: normalized(points, day: day, now: now), source: source, refreshedAt: now)
            result[kind] = result[kind].map { $0.merging(series) } ?? series
        }
        func values(_ key: String, descriptors: String, value: String, bounds: ClosedRange<Double>) -> [MetricSeriesPoint] {
            rows(object[key] as? [[Any]] ?? [], descriptors: object[descriptors] as? [[String: Any]] ?? [], valueKey: value, bounds: bounds)
        }
        switch endpoint {
        case .heartRate:
            add(.heartRate, values("heartRateValues", descriptors: "heartRateValueDescriptors", value: "heartrate", bounds: 1...399))
        case .stress:
            add(.stress, values("stressValuesArray", descriptors: "stressValueDescriptorsDTOList", value: "stressLevel", bounds: 0...100))
            add(.bodyBattery, values("bodyBatteryValuesArray", descriptors: "bodyBatteryValueDescriptorsDTOList", value: "bodyBatteryLevel", bounds: 0...100))
        case .bodyBattery:
            add(.bodyBattery, values("bodyBatteryValuesArray", descriptors: "bodyBatteryValueDescriptorDTOList", value: "bodyBatteryLevel", bounds: 0...100))
        case .respiration:
            add(MetricKind(rawValue: "respiration")!, values("respirationValuesArray", descriptors: "respirationValueDescriptorsDTOList", value: "respiration", bounds: 0.1...100))
        case .spo2:
            let descriptors = object["spO2ValueDescriptorsDTOList"] as? [[String: Any]] ?? []
            var readings = rows(object["spO2SingleValues"] as? [[Any]] ?? [], descriptors: descriptors, valueKey: "spo2Reading", bounds: 1...100).map { point -> MetricSeriesPoint in var p = point; p.label = "单次测量"; return p }
            for continuous in object["continuousReadingDTOList"] as? [[String: Any]] ?? [] {
                readings += rows(continuous["spO2ContinuousValues"] as? [[Any]] ?? [], descriptors: [], valueKey: "spo2Reading", bounds: 1...100).map { point -> MetricSeriesPoint in var p = point; p.label = "连续测量"; return p }
            }
            // Hourly averages are distinct observations, never replacements for
            // a continuous reading in the same hour.
            let hours = Set(readings.filter { $0.value != nil }.map { Int($0.timestamp.timeIntervalSince1970 / 3600) })
            readings += rows(object["spO2HourlyAverages"] as? [[Any]] ?? [], descriptors: [], valueKey: "spo2Reading", bounds: 1...100).filter { !hours.contains(Int($0.timestamp.timeIntervalSince1970 / 3600)) }.map { point -> MetricSeriesPoint in var p = point; p.label = "小时均值"; return p }
            add(MetricKind(rawValue: "spo2")!, readings, "佳明中国 · 连续/单次测量与小时均值")
        case .steps:
            let rows = root as? [[String: Any]] ?? []
            for (key, kind) in [("steps", MetricKind.steps), ("pushes", MetricKind(rawValue: "pushes")!)] {
                let readings = rows.compactMap { row -> MetricSeriesPoint? in
                    guard let start = timestamp(row["startGMT"]), let end = timestamp(row["endGMT"]), end > start else { return nil }
                    return MetricSeriesPoint(timestamp: start, value: number(row[key], bounds: 0...1_000_000), end: min(end, now))
                }
                add(kind, readings, "佳明中国 · 分时新增数量")
            }
        case .floors:
            let descriptors = object["floorsValueDescriptorDTOList"] as? [[String: Any]] ?? []
            let rows = object["floorValuesArray"] as? [[Any]] ?? []
            for (key, kind) in [("floorsAscended", MetricKind(rawValue: "floors")!), ("floorsDescended", MetricKind(rawValue: "daily.floorsDescended")!)] {
                let readings = rows.compactMap { row -> MetricSeriesPoint? in
                    let startIndex = index("startTimeGMT", in: descriptors, fallback: 0)
                    let endIndex = index("endTimeGMT", in: descriptors, fallback: 1)
                    let valueIndex = index(key, in: descriptors, fallback: key == "floorsAscended" ? 2 : 3)
                    guard row.indices.contains(startIndex), row.indices.contains(endIndex), row.indices.contains(valueIndex),
                          let start = timestamp(row[startIndex]), let end = timestamp(row[endIndex]), end > start else { return nil }
                    return MetricSeriesPoint(timestamp: start, value: number(row[valueIndex], bounds: 0...10000), end: min(end, now))
                }
                add(kind, readings, "佳明中国 · 分时新增楼层")
            }
        }
        return result
    }

    static func rows(_ rows: [[Any]], descriptors: [[String: Any]], valueKey: String, bounds: ClosedRange<Double>) -> [MetricSeriesPoint] {
        let timeIndex = index("timestamp", in: descriptors, fallback: 0)
        let valueIndex = index(valueKey, in: descriptors, fallback: 1)
        return rows.compactMap { row in
            guard row.indices.contains(timeIndex), row.indices.contains(valueIndex), let date = timestamp(row[timeIndex]) else { return nil }
            let value = number(row[valueIndex], bounds: bounds)
            return MetricSeriesPoint(timestamp: date, value: value, unavailable: value == nil ? "不可测 / 缺测" : nil)
        }
    }
    private static func index(_ key: String, in descriptors: [[String: Any]], fallback: Int) -> Int {
        for descriptor in descriptors {
            if descriptor.values.contains(where: { ($0 as? String)?.lowercased() == key.lowercased() }) {
                for (name, value) in descriptor where name.lowercased().hasSuffix("index") {
                    if let index = value as? Int, (0..<32).contains(index) { return index }
                }
            }
        }
        return descriptors.isEmpty ? fallback : -1
    }
    private static func timestamp(_ value: Any?) -> Date? {
        if let text = value as? String { return GarminHealthMetrics.gmtDate(text) }
        guard let n = value as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID(), n.doubleValue.isFinite else { return nil }
        let seconds = n.doubleValue > 100_000_000_000 ? n.doubleValue / 1000 : n.doubleValue
        return Date(timeIntervalSince1970: seconds)
    }
    private static func number(_ value: Any?, bounds: ClosedRange<Double>) -> Double? {
        guard let n = value as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID(), n.doubleValue.isFinite, bounds.contains(n.doubleValue) else { return nil }
        return n.doubleValue
    }
    private static func normalized(_ points: [MetricSeriesPoint], day: Date, now: Date) -> [MetricSeriesPoint] {
        let filtered = points.filter { Calendar.current.isDate($0.timestamp, inSameDayAs: day) && $0.timestamp <= now && ($0.end == nil || $0.end! > $0.timestamp) }
        return Dictionary(filtered.map { ($0.timestamp, $0) }, uniquingKeysWith: { old, new in new.value == nil && old.value != nil ? old : new }).values.sorted { $0.timestamp < $1.timestamp }
    }
}

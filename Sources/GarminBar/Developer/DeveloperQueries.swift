import Foundation
import CoreFoundation

struct DeveloperQuerySnapshot {
    var metrics: [MetricKind: MetricSample]
    var freshness: [MetricKind: MetricFreshness]
    var hrvReport: GarminHRVReport?
    var history: [String: [MetricKind: MetricDaySeries]]
    var reader: HealthHistoryReader
    var activityIndex: GarminActivityIndex
    var activityStore: GarminActivityStore?
    var statusValue: [String: Any]
    var observedAt: Date
    var metadata: [MetricKind: (title: String, unit: String)]
    var loadedDays: Set<String> = []
    var historyIssues: [String: [String]] = [:]

    func cachedHistory(day: Date) -> HealthHistoryResult {
        let key = GarminHealthMetrics.calendarDate(day)
        if loadedDays.contains(key) { return HealthHistoryResult(series: history[key] ?? [:], issues: historyIssues[key] ?? []) }
        var result = reader.read(day: day, now: observedAt)
        for (kind, series) in history[key] ?? [:] { result.series[kind] = result.series[kind].map { $0.merging(series) } ?? series }
        return result
    }

    func query(_ route: String, arguments: [String:Any]) throws -> Any {
        if route == "summary" { return try healthSummary(arguments) }
        if ["activities", "activity", "activity_series"].contains(route) {
            return try ActivityQueries.query(route, arguments: arguments, index: activityIndex,
                detail: { activityStore?.detail($0) }, formats: { activityStore?.formats($0) ?? [] },
                hasDetail: { activityStore?.hasDetail($0) ?? false })
        }
        let allowed: Set<String> = route == "series" ? ["metric","date","offset","limit"] : route == "hrv" ? ["date"] : []
        guard Set(arguments.keys).isSubset(of:allowed) else { throw DeveloperError.invalid("Unknown query parameter") }
        let formatter = ISO8601DateFormatter()
        func stamp(_ date: Date) -> String { formatter.string(from:date) }
        func dateArgument(_ required: Bool = true) throws -> Date? {
            guard let raw = arguments["date"] else { if required { throw DeveloperError.invalid("date is required") }; return nil }
            guard let text = raw as? String, let date = GarminHRV.date(text), date <= Date() else { throw DeveloperError.invalid("date must be a non-future YYYY-MM-DD") }; return date
        }
        func points(_ values: [MetricSeriesPoint]) -> [[String:Any]] {
            values.map { ["time":stamp($0.timestamp),"value":$0.value as Any? ?? NSNull(),"origin":$0.origin.rawValue,"end":$0.end.map(stamp) as Any? ?? NSNull()] }
        }
        func integer(_ key: String, fallback: Int, range: ClosedRange<Int>) throws -> Int {
            guard let raw = arguments[key] else { return fallback }
            guard let number = raw as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(), number.doubleValue.isFinite,
                  number.doubleValue.rounded() == number.doubleValue, range.contains(number.intValue) else { throw DeveloperError.invalid("Invalid " + key) }
            return number.intValue
        }
        switch route {
        case "status":
            return statusValue
        case "metrics":
            let rows: [[String:Any]] = MetricKind.allCases.compactMap { kind in
                guard let sample = metrics[kind], sample.value.isFinite else { return nil }
                var row: [String:Any] = ["id":kind.rawValue,"name":metadata[kind]?.title ?? kind.rawValue,"value":sample.value,"unit":metadata[kind]?.unit ?? "","origin":sample.origin.rawValue,"recordedAt":stamp(sample.timestamp),"stale":freshness[kind]?.stale ?? true]
                if let timing = freshness[kind] {
                    row["syncedAt"] = timing.syncedAt.map(stamp) as Any? ?? NSNull()
                    row["ageSeconds"] = sample.timestampIsMeasurement == false ? NSNull() : timing.ageSeconds as Any
                    if sample.timestampIsMeasurement == false {
                        row["recordedAt"] = NSNull()
                        row["recordDate"] = GarminHealthMetrics.calendarDate(sample.timestamp)
                    }
                    row["suitableForCurrentState"] = timing.suitableForCurrentState
                    row["temporalKind"] = timing.temporalKind
                }
                row["deviceStatus"] = kind.isDeviceStatus
                if kind == .hrvStatus { row["status"] = GarminHRVStatus(rawValue:Int(sample.value)).map { String(describing:$0) } ?? "unknown" }
                if kind.rawValue == "hrv" { row["limitation"] = "Provisional service-12 reading; not a validated continuous RR stream or realtime HRV." }
                if kind.isOvernightHRV { row["recordDate"] = GarminHealthMetrics.calendarDate(sample.timestamp); row["syncedAt"] = hrvReport.map { stamp($0.refreshedAt) } ?? "" }
                return row
            }
            return ["schemaVersion":1,"observedAt":stamp(observedAt),"metrics":rows]
        case "catalog":
            return ["schemaVersion":1,"metrics":MetricKind.allCases.map { kind -> [String:Any] in
                ["id":kind.rawValue,"name":metadata[kind]?.title ?? kind.rawValue,"unit":metadata[kind]?.unit ?? "","available":metrics[kind] != nil,"timeline":kind.timelineKind != nil || kind.isOvernightHRV,"overnightHRV":kind.isOvernightHRV,"deviceStatus":kind.isDeviceStatus]
            }]
        case "series":
            guard let raw = arguments["metric"] as? String, let kind = MetricKind(rawValue:raw), !kind.isOvernightHRV else { throw DeveloperError.invalid("Use a valid time-series metric ID; use hrv for overnight HRV") }
            guard kind.timelineKind != nil else { throw DeveloperError.invalid("Metric is a daily scalar, not a time series") }
            let day = try dateArgument()!, offset = try integer("offset",fallback:0,range:0...100000), limit = try integer("limit",fallback:1440,range:1...1440)
            let result = cachedHistory(day: day)
            let series = result.series[kind.timelineKind ?? kind]
            let all = series?.points ?? []
            let slice = Array(all.dropFirst(offset).prefix(limit))
            return ["schemaVersion":1,"metric":raw,"timelineMetric":(kind.timelineKind ?? kind).rawValue,"date":GarminHealthMetrics.calendarDate(day),"timezone":TimeZone.current.identifier,"unit":metadata[kind.timelineKind ?? kind]?.unit ?? "","points":points(slice),"total":all.count,"nextOffset":offset + slice.count < all.count ? offset + slice.count as Any : NSNull(),"cached":series != nil,"issues":result.issues]
        case "hrv":
            let day = try dateArgument(false), summaries = (hrvReport?.summaries ?? []).filter { day == nil || Calendar.current.isDate($0.day,inSameDayAs:day!) }
            let rows: [[String:Any]] = summaries.map { item in
                ["date":GarminHealthMetrics.calendarDate(item.day),"nightlyAverage":item.night as Any? ?? NSNull(),"weeklyAverage":item.weekly as Any? ?? NSNull(),"highestFiveMinutes":item.high as Any? ?? NSNull(),"baselineLow":item.baselineLow as Any? ?? NSNull(),"baselineHigh":item.baselineHigh as Any? ?? NSNull(),"status":item.status.map { String(describing:$0) } as Any? ?? NSNull()]
            }
            let night = day.flatMap { hrvReport?.nights[GarminHealthMetrics.calendarDate($0)] }
            return ["schemaVersion":1,"unit":"ms","summaries":rows,"nightPoints":points(night ?? []),"nightCached":night != nil,"refreshedAt":hrvReport.map{stamp($0.refreshedAt)} as Any? ?? NSNull()]
        default: throw DeveloperError.invalid("Unknown query")
        }
    }
}

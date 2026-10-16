import Foundation
import CoreFoundation

enum ActivityQueries {
    static func query(_ route: String, arguments: [String: Any], index: GarminActivityIndex,
                      detail: (String) -> GarminActivityDetail?, formats: (String) -> [String]) throws -> [String: Any] {
        let allowed: Set<String> = route == "activities" ? ["offset", "limit", "startDate", "endDate", "type"] : route == "activity" ? ["id"] : ["id", "metric", "offset", "limit"]
        guard Set(arguments.keys).isSubset(of: allowed) else { throw DeveloperError.invalid("Unknown query parameter") }
        func integer(_ key: String, fallback: Int, maximum: Int) throws -> Int {
            guard let raw = arguments[key] else { return fallback }
            guard let number = GarminActivities.number(raw), number.rounded() == number,
                  (Double(key == "limit" ? 1 : 0)...Double(maximum)).contains(number) else { throw DeveloperError.invalid("Invalid " + key) }
            return Int(number)
        }
        func day(_ key: String) throws -> String? {
            guard let raw = arguments[key] else { return nil }
            guard let value = raw as? String, GarminHRV.date(value) != nil else { throw DeveloperError.invalid("Use YYYY-MM-DD for " + key) }
            return value
        }
        let stamp = ISO8601DateFormatter()
        func row(_ activity: GarminActivity) -> [String: Any] {
            ["id": activity.id, "name": activity.name, "type": activity.type,
             "startTimeGMT": activity.startTimeGMT as Any? ?? NSNull(), "startTimeLocal": activity.startTimeLocal as Any? ?? NSNull(),
             "statistics": activity.statistics, "fetchedAt": stamp.string(from: activity.fetchedAt)]
        }
        if route == "activities" {
            let start = try day("startDate"), end = try day("endDate")
            if let start, let end, start > end { throw DeveloperError.invalid("startDate must not follow endDate") }
            var type: String?
            if let raw = arguments["type"] {
                guard let value = raw as? String, !value.isEmpty, value.count <= 80 else { throw DeveloperError.invalid("Invalid activity type") }
                type = value
            }
            let offset = try integer("offset", fallback: 0, maximum: 1_000_000), limit = try integer("limit", fallback: 20, maximum: 100)
            let selected = index.activities.filter { activity in
                let date = activity.startTimeLocal.map { String($0.prefix(10)) }
                return (type == nil || activity.type == type) && (start == nil || (date != nil && date! >= start!)) && (end == nil || (date != nil && date! <= end!))
            }
            let page = selected.dropFirst(offset).prefix(limit).map { item -> [String: Any] in
                var result = row(item)
                result["detailCached"] = detail(item.id) != nil
                result["downloadedFormats"] = formats(item.id)
                return result
            }
            return ["schemaVersion": 1, "source": "localCache", "activities": page, "totalCachedMatches": selected.count,
                    "nextOffset": offset + page.count < selected.count ? offset + page.count as Any : NSNull(),
                    "historyEndReached": index.reachedEnd, "refreshedAt": index.refreshedAt.map { stamp.string(from: $0) } as Any? ?? NSNull()]
        }
        guard let id = arguments["id"] as? String, GarminActivities.validID(id) else { throw DeveloperError.invalid("id must be a positive decimal string") }
        guard let summary = index.activities.first(where: { $0.id == id }) else {
            return ["schemaVersion": 1, "id": id, "cached": false]
        }
        let cached = detail(id)
        if route == "activity" {
            return ["schemaVersion": 1, "cached": true, "activity": row(cached?.summary ?? summary), "detailCached": cached != nil,
                    "detailFetchedAt": cached.map { stamp.string(from: $0.fetchedAt) } as Any? ?? NSNull(),
                    "chartAvailable": cached?.chartAvailable ?? false, "chartPointLimit": cached?.chartPointLimit as Any? ?? NSNull(),
                    "seriesMetrics": cached?.series.map(\.key) ?? [], "downloadedFormats": formats(id), "completeRecording": false]
        }
        guard route == "activity_series", let metric = arguments["metric"] as? String, GarminActivities.seriesKeys.contains(metric) else { throw DeveloperError.invalid("Invalid chart metric") }
        let offset = try integer("offset", fallback: 0, maximum: 100_000), limit = try integer("limit", fallback: 250, maximum: 500)
        let series = cached?.series.first { $0.key == metric }, values = series?.values ?? []
        let page: [Any] = values.dropFirst(offset).prefix(limit).map { $0 as Any? ?? NSNull() }
        return ["schemaVersion": 1, "id": id, "metric": metric, "cached": series != nil, "values": page,
                "offset": offset, "total": values.count, "nextOffset": offset + page.count < values.count ? offset + page.count as Any : NSNull(),
                "unit": series?.unit as Any? ?? NSNull(), "factor": series?.factor as Any? ?? NSNull(),
                "valueEncoding": "Garmin chart values with original descriptor; no unit conversion applied",
                "completeRecording": false, "fetchedAt": cached.map { stamp.string(from: $0.fetchedAt) } as Any? ?? NSNull()]
    }
}

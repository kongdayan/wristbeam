import Foundation

extension DeveloperQuerySnapshot {
    func healthSummary(_ arguments: [String: Any]) throws -> [String: Any] {
        guard Set(arguments.keys).isSubset(of: ["startDate", "endDate", "metrics"]),
              let startText = arguments["startDate"] as? String, let endText = arguments["endDate"] as? String,
              let start = GarminHRV.date(startText), let end = GarminHRV.date(endText),
              start <= end, end <= observedAt,
              let span = Calendar.current.dateComponents([.day], from: start, to: end).day, span < 31 else {
            throw DeveloperError.invalid("Use startDate/endDate (YYYY-MM-DD), ordered, non-future, at most 31 days")
        }
        let defaults: [MetricKind] = [.heartRate, .stress, .bodyBattery, .steps]
        let kinds: [MetricKind]
        if let raw = arguments["metrics"] {
            let names = (raw as? [String]) ?? (raw as? String)?.components(separatedBy: ",")
            guard let names, !names.isEmpty, names.count <= 12 else { throw DeveloperError.invalid("Select 1–12 timeline metrics") }
            kinds = try names.map {
                guard let kind = MetricKind(rawValue: $0), kind.timelineKind == kind, !kind.isOvernightHRV else {
                    throw DeveloperError.invalid("Use canonical timeline metric IDs")
                }
                return kind
            }
            guard Set(kinds).count == kinds.count else { throw DeveloperError.invalid("Duplicate metric") }
        } else { kinds = defaults }
        let formatter = ISO8601DateFormatter()
        var days: [[String: Any]] = []
        for offset in 0...span {
            let day = Calendar.current.date(byAdding: .day, value: offset, to: start)!, key = GarminHealthMetrics.calendarDate(day)
            let loaded = reader.read(day: day, now: observedAt)
            var collection = loaded.series
            for (kind, series) in history[key] ?? [:] { collection[kind] = collection[kind].map { $0.merging(series) } ?? series }
            let summaries: [[String: Any]] = kinds.map { kind in
                let series = collection[kind], points = series?.values ?? []
                let covered = Set(points.map { Int($0.timestamp.timeIntervalSince1970 / 60) }).count
                var row: [String: Any] = ["metric": kind.rawValue, "unit": metadata[kind]?.unit ?? "", "available": !points.isEmpty,
                    "sampleCount": points.count, "observedMinuteCount": covered,
                    "firstRecordedAt": points.first.map { formatter.string(from: $0.timestamp) } as Any? ?? NSNull(),
                    "lastRecordedAt": points.last.map { formatter.string(from: $0.timestamp) } as Any? ?? NSNull(),
                    "sources": Array(Set(points.map { $0.origin.rawValue })).sorted()]
                // Empty data must never become zero. A sample mean is not a time-weighted daily mean.
                row["minimum"] = series?.minimum as Any? ?? NSNull()
                row["maximum"] = series?.maximum as Any? ?? NSNull()
                row["sampleMean"] = series?.mean as Any? ?? NSNull()
                if kind.seriesStyle == .bars && kind != .stress { row["recordedIntervalTotal"] = series?.total as Any? ?? NSNull() }
                return row
            }
            let workouts = activityIndex.activities.filter { $0.startTimeLocal?.hasPrefix(key) == true }
            let nightly = hrvReport?.summaries.first { Calendar.current.isDate($0.day, inSameDayAs: day) }
            days.append(["date": key, "metrics": summaries, "missingMetrics": kinds.filter { collection[$0]?.values.isEmpty != false }.map(\.rawValue),
                "issues": loaded.issues, "cachedWorkoutCount": workouts.count,
                "workoutDurationSeconds": workouts.compactMap { $0.statistics["duration"] }.reduce(0, +),
                "nightlyHRV": nightly?.night as Any? ?? NSNull(), "weeklyHRV": nightly?.weekly as Any? ?? NSNull()])
        }
        return ["schemaVersion": 1, "startDate": startText, "endDate": endText, "timezone": TimeZone.current.identifier,
            "generatedAt": formatter.string(from: observedAt), "source": "localCache", "days": days,
            "activityHistoryComplete": activityIndex.reachedEnd,
            "coverageNote": "Observed minutes count samples, not continuous monitoring. Missing intervals remain unknown. Workout history may be partial. No network refresh was triggered."]
    }
}

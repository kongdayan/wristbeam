import Foundation

@MainActor extension AppModel {
    func developerSnapshot() -> DeveloperQuerySnapshot {
        activities.reconcile()
        let formatter = ISO8601DateFormatter()
        var status: [String: Any] = ["schemaVersion": 1, "watchConnected": bluetooth.isConnected,
            "fileChannelReady": bluetooth.canSyncFiles, "cloudConnected": cloud.isAuthenticated,
            "pendingFiles": uploads.pendingCount, "readOnly": true, "demo": preview,
            "storageIssues": storageIssues.sorted(), "watchBattery": NSNull()]
        if let battery = metrics[.watchBattery], battery.value.isFinite, (0...100).contains(battery.value) {
            status["watchBattery"] = ["percent": battery.value, "recordedAt": formatter.string(from: battery.timestamp),
                "stale": isStale(.watchBattery), "charging": bluetooth.batteryCharging as Any? ?? NSNull()]
        }
        return DeveloperQuerySnapshot(metrics: metrics, freshness: metrics.mapValues { freshness($0) },
            hrvReport: hrvReport, history: seriesDays, reader: historyReader, activityIndex: activities.index,
            activityStore: activities.store, statusValue: status, observedAt: Date(),
            metadata: Dictionary(uniqueKeysWithValues: MetricKind.allCases.map { ($0, (title: $0.title, unit: $0.unit)) }))
    }
    // Used only for lightweight in-memory webhook snapshots. HTTP queries run on a utility task.
    func developerQuery(_ route: String, arguments: [String: Any]) throws -> Any {
        try developerSnapshot().query(route, arguments: arguments)
    }
}

import Foundation

@MainActor extension AppModel {
    var workflow: WorkflowPresentation {
        WorkflowPresentation(connected: bluetooth.isConnected, connecting: bluetooth.isConnecting,
            receiving: bluetooth.isTransferringFiles, cloudEnabled: cloudSyncEnabled, authenticated: cloud.isAuthenticated,
            uploading: uploads.isSyncing, pendingFiles: uploads.pendingCount,
            hasLocalData: lastLocalSavedAt != nil || localDataSummary.fitFiles > 0 || localDataSummary.telemetryDays > 0 || !uploads.visibleJobs.isEmpty,
            storageFailed: !storageIssues.isEmpty)
    }
    var mainScrollKey: String {
        if let kind = detailMetric { return "metric." + kind.rawValue }
        if page == .activities, let id = selectedActivityID { return "activity." + id }
        if page == .connectIQ { return "page.connectIQ.\(connectIQScope)" }
        return "page." + page.rawValue
    }
    var canGoBack: Bool { detailMetric != nil || (page == .activities && selectedActivityID != nil) }
    func goBack() {
        if detailMetric != nil { detailMetric = nil }
        else if page == .activities { selectedActivityID = nil }
    }
    func selectActivity(_ id: String) { selectedActivityID = id }
    func resetActivityBrowsing() {
        selectedActivityID = nil; activityBrowsing = ActivityBrowsingState(); scrollPositions.clearActivities()
    }
    func refreshCurrentPage() {
        guard !preview else { return }
        if let kind = detailMetric {
            let day = detailDay
            Task {
                if kind.isOvernightHRV { await refreshHealthMetrics(force: true); await loadHRVNight(day) }
                else { await refreshSeries(day: day, force: true) }
            }
        } else if page == .overview { refreshMetricsNow() }
        else if page == .activities {
            guard activities.online, !activities.busy else { return }
            Task {
                if let id = selectedActivityID { await activities.downloadDetail(id) }
                else { activities.requestPage(older: false) }
            }
        } else if page == .sync { syncNow() }
    }
}

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
        if detailMetric != nil || page == .overview { refreshMetricsNow() }
        else if page == .activities {
            guard activities.online, !activities.busy else { return }
            Task {
                if let id = selectedActivityID { await activities.downloadDetail(id) }
                else { await activities.loadPage(older: false) }
            }
        } else if page == .sync { syncNow() }
    }
}

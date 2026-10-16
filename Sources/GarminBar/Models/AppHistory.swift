import Foundation
import AppKit
import UniformTypeIdentifiers

@MainActor extension AppModel {
    var historyReader: HealthHistoryReader {
        HealthHistoryReader(telemetry: AppPaths.directory("Telemetry"), charts: seriesStore,
            legacyCharts: cloud.region == .china && !cloud.accountGUID.isEmpty ? MetricSeriesStore(accountGUID: cloud.accountGUID) : nil)
    }
    func series(for kind: MetricKind, day: Date? = nil) -> MetricDaySeries? {
        if kind.isOvernightHRV { return hrvReport?.trend(kind) }
        guard let canonical = kind.timelineKind else { return nil }
        return seriesDays[GarminHealthMetrics.calendarDate(day ?? now)]?[canonical]
    }
    func mergeSeries(_ incoming: [MetricKind: MetricDaySeries], day: Date) {
        let key = GarminHealthMetrics.calendarDate(day)
        var collection = seriesDays[key] ?? [:]
        for (kind, series) in incoming where !kind.isDeviceStatus { collection[kind] = collection[kind].map { $0.merging(series) } ?? series }
        seriesDays[key] = collection
        // Bound memory without deleting stored history. Requested dates reload.
        if seriesDays.count > 10, let oldest = seriesDays.keys.sorted().first, oldest != key { seriesDays.removeValue(forKey: oldest) }
    }
    func restoreSeries(day: Date) {
        let store = seriesStore, reader = historyReader
        Task { @MainActor [weak self] in
            let result = await Task.detached(priority: .utility) { reader.read(day: day) }.value
            guard let self, self.seriesStore === store else { return }
            self.mergeSeries(result.series, day: day)
            self.storageIssues.formUnion(result.issues)
        }
    }
    func saveSeries(_ collection: [MetricKind: MetricDaySeries], day: Date) async {
        guard let store = seriesStore else { return }
        let key = GarminHealthMetrics.calendarDate(day)
        pendingChartSaves[key] = collection
        let saved = await Task.detached(priority: .utility) { () -> Bool in
            for _ in 0..<3 {
                do { try store.saveChecked(collection, day: day); return true } catch { }
            }
            return false
        }.value
        guard seriesStore === store else { return }
        if saved { pendingChartSaves.removeValue(forKey: key); if pendingChartSaves.isEmpty { storageIssues.remove("chartWriteFailed") } }
        else { storageIssues.insert("chartWriteFailed") }
    }
    func retryLocalStorage() {
        journal.retry()
        Task {
            for (key, values) in pendingChartSaves { if let day = GarminHRV.date(key) { await saveSeries(values, day: day) } }
            restoreSeries(day: detailDay)
            refreshLocalDataSummary()
        }
    }
    func refreshSeries(day: Date, force: Bool = false) async {
        let key = GarminHealthMetrics.calendarDate(day)
        if !preview, seriesDays[key] == nil { restoreSeries(day: day) }
        guard !preview, cloudSyncEnabled, cloud.isAuthenticated, !loadingSeriesDays.contains(key),
              force || Date().timeIntervalSince(lastSeriesRefresh[key] ?? .distantPast) >= Double(max(1, metricRefreshInterval)) * 60 else { return }
        let device = watchUnitID.isEmpty ? cloud.deviceId : watchUnitID
        guard !device.isEmpty, cloud.devices.contains(where: { $0.id == device }) else { return }
        if seriesDays[key] == nil { restoreSeries(day: day) }
        let owner = seriesOwner
        loadingSeriesDays.insert(key); lastSeriesRefresh[key] = Date()
        defer { loadingSeriesDays.remove(key) }
        let snapshot = await cloud.dailySeries(deviceID: device, day: day)
        guard seriesOwner == owner else { return }
        mergeSeries(snapshot.series, day: day)
        seriesNotes[key] = snapshot.notes
        seriesStatus = snapshot.detail
        if let collection = seriesDays[key] { await saveSeries(collection, day: day) }
        if Calendar.current.isDateInToday(day) {
            for series in snapshot.series.values where series.kind.definition.dailyKey == nil {
                if let latest = series.latest, let value = latest.value, !["floors", "pushes"].contains(series.kind.rawValue) {
                    receive(MetricSample(kind: series.kind, value: value, source: "\(cloud.region.title) · 最近同步读数", timestamp: latest.timestamp, origin: .cloud))
                }
            }
        }
    }

    func refreshLocalDataSummary() {
        guard !preview else { return }
        let root = AppPaths.root
        Task {
            let summary = await Task.detached(priority: .utility) { LocalDataArchive.summary(root: root) }.value
            self.localDataSummary = summary
        }
    }
    func uploadStoredFiles() {
        guard cloudSyncEnabled, cloud.isAuthenticated, !preview else { openSettings(.account); return }
        Task { await uploads.syncNow(force: true) }
    }
    func exportLocalData() {
        guard !preview, !isExportingLocalData else { return }
        let panel = NSSavePanel(); panel.allowedContentTypes = [.zip]
        panel.nameFieldStringValue = "WristBeam-Local-Data.zip"
        panel.prompt = L10n.text("导出暂存数据")
        guard panel.runModal() == .OK, let destination = panel.url else { return }
        isExportingLocalData = true; localExportStatus = "正在导出暂存数据"
        let root = AppPaths.root
        Task {
            defer { isExportingLocalData = false }
            do {
                try await Task.detached(priority: .utility) { try LocalDataArchive.export(root: root, to: destination) }.value
                localExportStatus = "暂存数据已导出"
            } catch { localExportStatus = "导出未完成，原始数据保留" }
        }
    }
}

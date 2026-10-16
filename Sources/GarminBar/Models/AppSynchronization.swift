import Foundation
import AppKit
import UniformTypeIdentifiers

@MainActor extension AppModel {
    func tickSynchronization(at date: Date) {
        let previousStage = bluetooth.connectionStage(now: now)
        let oldStale = Set(metrics.keys.filter { isStale($0) })
        let previousDay = Calendar.current.startOfDay(for: now)
        now = date
        if previousStage != bluetooth.connectionStage(now: date) || oldStale != Set(metrics.keys.filter { isStale($0) }) || previousDay != Calendar.current.startOfDay(for: date) {
            objectWillChange.send()
        }
        developer.tick()
        if !preview { activities.tick(now: date) }
        if date.timeIntervalSince(lastStatusWrite) >= 5 { writeRuntimeState() }
        if autoRefreshMetrics && date.timeIntervalSince(lastHealthRefresh) >= Double(max(1, metricRefreshInterval)) * 60 { Task { await refreshHealthMetrics() } }
        if autoSync && !preview && date.timeIntervalSince(lastAutoSync) >= Double(max(1, syncInterval)) * 60 {
            lastAutoSync = date
            if bluetooth.canSyncFiles { bluetooth.requestFileSync() }
            if cloudSyncEnabled && autoUpload && cloud.isAuthenticated { Task { await uploads.syncNow(force: false) } }
        }
    }
    func resumeAfterWake() {
        guard !preview else { return }
        bluetooth.resumeAfterWake()
        developer.resumeAfterWake()
        if autoRefreshMetrics { lastHealthRefresh = .distantPast }
        if autoSync { lastAutoSync = .distantPast }
        activities.tick(now: Date())
    }
    func syncNow() {
        guard !preview else { return }
        if bluetooth.canSyncFiles {
            manualFileSync = true; bluetooth.requestFileSync()
        } else {
            if bluetooth.sessionActivated {
                fileSyncRequested = true; bluetooth.reconnectSaved()
            } else { openSettings(.watch) }
        }
    }
    func syncRecentActivity() {
        guard !preview else { return }
        if bluetooth.canSyncFiles {
            manualFileSync = true; bluetooth.requestRecentActivity()
        } else {
            if bluetooth.sessionActivated {
                recentSyncRequested = true; bluetooth.reconnectSaved()
            } else { openSettings(.watch) }
        }
    }
    func importFIT() {
        let panel = NSOpenPanel(); panel.allowedContentTypes = [UTType(filenameExtension: "fit") ?? .data]; panel.allowsMultipleSelection = true
        panel.prompt = L10n.text("暂存原始文件")
        panel.message = L10n.text("原始 FIT 会先保存在本机。开启云同步并登录后，可以选择补传。")
        guard panel.runModal() == .OK else { return }
        for url in panel.urls {
            do {
                try uploads.importFIT(fileURL: url, deviceID: watchUnitID.isEmpty ? cloud.deviceId : watchUnitID)
                log("已导入 \(url.lastPathComponent)")
            } catch { log("导入失败：\(error.localizedDescription)") }
        }
        refreshLocalDataSummary()
        if cloudSyncEnabled && autoUpload && !preview { Task { await uploads.syncNow(force: false) } }
    }
    func watchFITFolder() {
        let panel = NSOpenPanel(); panel.canChooseFiles = false; panel.canChooseDirectories = true
        panel.prompt = L10n.text("选择并监测此文件夹")
        panel.message = L10n.text("将所选文件夹中的新增 FIT 暂存到本机；云上传由独立开关控制。")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        uploads.startWatching(directory: url)
        log(uploads.watchedDirectory == url ? "已启用 FIT 文件夹自动同步" : uploads.status)
    }
}

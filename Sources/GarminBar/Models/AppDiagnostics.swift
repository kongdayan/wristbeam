import Foundation
import AppKit

private enum RuntimeStateWriter {
    static let queue = DispatchQueue(label: "cn.wristbeam.runtime-state", qos: .utility)
    static func write(_ state: [String: Any], to url: URL) {
        queue.async {
            if let data = try? JSONSerialization.data(withJSONObject: state, options: [.prettyPrinted, .sortedKeys]) {
                try? GarminPrivateFile.write(data, to: url)
            }
        }
    }
}

@MainActor extension AppModel {
    func writeRuntimeState() {
        lastStatusWrite = Date()
        let state: [String: Any] = [
            "reportedAt": lastStatusWrite.timeIntervalSince1970,
            "pid": ProcessInfo.processInfo.processIdentifier,
            "bundleIdentifier": Bundle.main.bundleIdentifier ?? "unbundled",
            "watchConnected": bluetooth.isConnected,
            "watchConnecting": bluetooth.isConnecting,
            "bluetoothStatus": bluetooth.bluetoothStatus,
            "bluetoothPermission": bluetooth.permissionState,
            "bluetoothManagerState": bluetooth.managerState ?? -1,
            "bluetoothSessionActivated": bluetooth.sessionActivated,
            "connectsOnLaunch": bluetooth.connectsOnLaunch,
            "automaticFileSync": autoSync,
            "watchConnectionStatus": bluetooth.status,
            "fileChannelReady": bluetooth.canSyncFiles,
            "developerRunning": developer.running,
            "developerApplying": developer.isApplying,
            "developerConfigurationPending": developer.hasUnappliedChanges,
            "developerError": developer.configurationError,
            "developerKeyStatus": developer.keyStatus,
            "protocolReady": bluetooth.protocolReady,
            "connectIQReadStatus": bluetooth.watchFaceStatus,
            "connectIQOpenStatus": bluetooth.watchFaceOpenStatus,
            "connectIQDownloadStatus": connectIQ.status,
            "connectIQInstallStatus": bluetooth.connectIQInstallStatus,
            "connectIQInstallBusy": bluetooth.connectIQInstallBusy,
            "connectIQInstallProgress": bluetooth.connectIQInstallProgress,
            "connectIQSettingsStatus": bluetooth.connectIQSettingsStatus,
            "connectIQSettingsBusy": bluetooth.connectIQSettingsBusy,
            "connectIQSettingsBytes": bluetooth.connectIQSettingsSnapshot?.rawData.count ?? 0,
            "connectIQSettingsVerified": bluetooth.connectIQSettingsSnapshot?.savedAndVerified ?? false,
            "connectIQInstalledFaces": bluetooth.installedWatchFaces.map {
                ["id": $0.id, "name": $0.name, "version": $0.version.map(Int.init) ?? -1,
                 "filename": $0.filename ?? "", "disabled": $0.disabled] as [String: Any]
            },
            "watchRequestCaptureActive": bluetooth.requestCapture.isCapturing,
            "watchRequestCaptureEvents": bluetooth.requestCapture.log.totalEvents,
            "watchRequestCaptureStorageError": bluetooth.requestCapture.storageError,
            "watchWeatherEnabled": weather.enabled,
            "watchWeatherSource": weather.source.rawValue,
            "watchWeatherConfigured": weather.location != nil,
            "watchWeatherStatus": weather.status,
            "watchWeatherLastDelivered": weather.lastDelivered?.timeIntervalSince1970 ?? 0,
            "liveSampleCount": bluetooth.liveSampleCount,
            "lastLiveSampleAt": bluetooth.lastLiveSampleAt?.timeIntervalSince1970 ?? 0,
            "registeredMetrics": bluetooth.registeredMetrics.map(\.rawValue).sorted(),
            "nearbyWatches": bluetooth.nearby.filter(\.offersGarmin).map { ["name": $0.name, "id": $0.id.uuidString, "rssi": $0.rssi] as [String: Any] },
            "watchFileStatus": bluetooth.transferStatus,
            "cloudSyncEnabled": cloudSyncEnabled,
            "automaticCloudUpload": autoUpload,
            "cloudRequestCount": cloud.requestCount,
            "cloudAuthenticated": cloud.isAuthenticated,
            "cloudRegion": cloud.region.rawValue,
            "uploadQueueStatus": uploads.status,
            "pendingFileCount": uploads.pendingCount,
            "metrics": Dictionary(uniqueKeysWithValues: MetricKind.allCases.map { ($0.rawValue, display($0)) }),
            "metricSources": Dictionary(uniqueKeysWithValues: metrics.map { ($0.key.rawValue, $0.value.source) }),
            "healthStatus": healthStatus,
            "seriesStatus": seriesStatus,
            "seriesCounts": Dictionary(uniqueKeysWithValues: (seriesDays[GarminHealthMetrics.calendarDate(Date())] ?? [:]).map { ($0.key.rawValue, $0.value.values.count) }),
            "detailMetric": detailMetric?.rawValue ?? "",
            "detailDate": GarminHealthMetrics.calendarDate(detailDay),
            "chartPlotBuilds": ChartRenderDiagnostics.plotBuilds,
            "chartCursorEvents": ChartRenderDiagnostics.cursorEvents,
            "floatingMetrics": visibleMetrics.map(\.rawValue),
            "dashboardMetrics": dashboardVisibleMetrics.map(\.rawValue),
            "widgetMetrics": widgetMetrics.map(\.rawValue).sorted(),
            "widgetStatus": widgetPublisher.status,
            "fontScale": fontScale,
            "appearance": appearance.rawValue,
            "menuMetrics": menuVisibleMetrics.map(\.rawValue),
            "uploadJobs": uploads.jobs.prefix(25).map { ["type": $0.dataType.rawValue, "state": $0.state.rawValue,
                "httpStatus": $0.cloudStatus?.httpStatus ?? 0, "detail": $0.detail] as [String: Any] },
            "lastControlRequest": lastControlRequest,
            "windows": NSApp.windows.map { ["title": $0.title, "number": $0.windowNumber, "visible": $0.isVisible, "minimized": $0.isMiniaturized] as [String: Any] },
            "recentEvents": events.prefix(12).map(\.message)
        ]
        RuntimeStateWriter.write(state, to: PulseLocalControl.statusURL)
    }
}

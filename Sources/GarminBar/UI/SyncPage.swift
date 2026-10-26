import SwiftUI
import AppKit

struct SyncPage: View {
    @ObservedObject var model: AppModel
    @State private var showSettings: Bool
    @State private var showFiles: Bool
    init(model: AppModel, initiallyExpanded: Bool = false) {
        self.model = model
        _showSettings = State(initialValue: initiallyExpanded)
        _showFiles = State(initialValue: initiallyExpanded)
    }
    var body: some View {
        VStack(alignment: .leading, spacing: PulseTheme.sectionSpacing) {
            PulseCard {
                VStack(alignment: .leading, spacing: 14) {
                    Label(L10n.text(model.workflow.summary), systemImage: model.storageIssues.isEmpty ? "externaldrive" : "exclamationmark.triangle")
                        .font(PulseTheme.font(size: 20, weight: .semibold))
                        .foregroundStyle(model.storageIssues.isEmpty ? Color.primary : PulseTheme.warning)
                    ViewThatFits(in: .horizontal) {
                        HStack(spacing: 10) { receiveAction; uploadAction; Spacer() }
                        VStack(alignment: .leading, spacing: 10) { receiveAction; uploadAction }
                    }
                    if model.bluetooth.isTransferringFiles || model.uploads.isSyncing { ProgressView().controlSize(.small) }
                    if !model.storageIssues.isEmpty {
                        Button(L10n.text("重试本地存储")) { model.retryLocalStorage() }.buttonStyle(PulseButtonStyle())
                    }
                }
            }
            SyncProgressView(model: model)
            PulseCard {
                VStack(alignment: .leading, spacing: 12) {
                    Text(L10n.text("本地数据")).font(PulseTheme.font(size: 17, weight: .semibold))
                    Text(L10n.format("{0} 份原始文件 · {1} 天读数 · {2}", String(model.localDataSummary.fitFiles), String(model.localDataSummary.telemetryDays), model.localDataSummary.sizeText))
                        .font(PulseTheme.font(size: 13))
                    Text(L10n.text("暂存不会自动删除。导出包含原始 FIT 和手表读数 CSV。"))
                        .font(PulseTheme.font(size: 12)).foregroundStyle(PulseTheme.secondary)
                    HStack {
                        Button(L10n.text("导出暂存数据")) { model.exportLocalData() }.disabled(model.preview || model.isExportingLocalData)
                        Button(L10n.text("打开本地数据")) { NSWorkspace.shared.open(AppPaths.root) }
                    }.buttonStyle(PulseButtonStyle())
                    if model.isExportingLocalData { ProgressView().controlSize(.small).accessibilityLabel(L10n.text("正在导出本地数据…")) }
                    if !model.localExportStatus.isEmpty { PulseNotice(text: model.localExportStatus) }
                }
            }
            PulseDisclosure(L10n.text("同步设置"), isExpanded: $showSettings) { SyncSetupGuide(model: model) }
            PulseDisclosure(L10n.text("文件与上传记录"), isExpanded: $showFiles) {
                VStack(alignment: .leading, spacing: 14) {
                    ViewThatFits(in: .horizontal) {
                        HStack { fileActions }
                        VStack(alignment: .leading, spacing: 10) { fileActions }
                    }.buttonStyle(PulseButtonStyle())
                    if let directory = model.uploads.watchedDirectory {
                        Text(L10n.text("自动同步：\(directory.lastPathComponent)"))
                        Button(L10n.text("停止文件夹同步")) { model.uploads.stopWatching() }.buttonStyle(PulseButtonStyle())
                    }
                    Button(L10n.text("同步最近一次运动")) { model.syncRecentActivity() }
                        .buttonStyle(PulseButtonStyle()).disabled(model.preview || !model.bluetooth.canSyncFiles)
                    if model.uploads.visibleJobs.isEmpty {
                        Text(L10n.text("暂无原始文件，连接手表接收数据或导入 FIT。" )).foregroundStyle(PulseTheme.secondary)
                    }
                    ForEach(model.uploads.visibleJobs.prefix(12)) { job in
                        PulseCard {
                            VStack(alignment: .leading, spacing: 7) {
                                HStack {
                                    Text(L10n.text(job.dataType.label)).font(PulseTheme.font(size: 12, weight: .medium)).help(job.originalName)
                                    Spacer()
                                    Text(L10n.text(!model.cloudSyncEnabled && !job.state.isComplete ? "已保存到本机" : job.state.label))
                                        .foregroundStyle(job.state.isComplete ? PulseTheme.mint : PulseTheme.secondary)
                                }
                                Text(job.createdAt, style: .date).foregroundStyle(PulseTheme.secondary)
                                if model.cloudSyncEnabled { Text(L10n.text(job.detail)).foregroundStyle(PulseTheme.secondary) }
                                if model.cloudSyncEnabled, job.dataType == .activity, job.state.isComplete,
                                   let id = job.cloudStatus?.activityID, !id.isEmpty, id.allSatisfy({ $0.isNumber }),
                                   let url = URL(string: "https://connect.\(model.cloud.region.domain)/modern/activity/\(id)") {
                                    Link(L10n.text("在\(model.cloud.region.title)查看运动 ↗"), destination: url)
                                }
                            }.font(PulseTheme.font(size: 11))
                        }
                    }
                }
            }
            PulseDisclosure(L10n.text("诊断与日志")) {
                VStack(alignment: .leading, spacing: 12) {
                    Text(L10n.text("手表：\(model.bluetooth.transferStatus)"))
                    if model.cloudSyncEnabled { Text(L10n.text(model.uploads.status)) }
                    Button(L10n.text("刷新存储信息")) { model.refreshLocalDataSummary() }.buttonStyle(PulseButtonStyle()).disabled(model.isReadingLocalStorage)
                    if model.isReadingLocalStorage { ProgressView().controlSize(.small).accessibilityLabel(L10n.text("正在读取存储信息…")) }
                    ForEach(model.events.prefix(25)) { event in
                        HStack(alignment: .top, spacing: 12) {
                            Text(event.date, style: .time).monospacedDigit().foregroundStyle(PulseTheme.secondary)
                            Text(L10n.text(event.message)).textSelection(.enabled)
                        }
                    }
                }.font(PulseTheme.font(size: 11))
            }
        }.font(PulseTheme.font(size: 13))
    }
    private var receiveAction: some View {
        Button { model.bluetooth.canSyncFiles ? model.syncNow() : model.openSettings(.watch) } label: {
            Label(L10n.text(model.bluetooth.canSyncFiles ? "接收手表数据" : "连接手表"), systemImage: "applewatch")
        }.buttonStyle(PulseButtonStyle(prominent: true))
            .disabled(model.preview || model.bluetooth.isTransferringFiles)
    }
    @ViewBuilder private var uploadAction: some View {
        if model.cloudSyncEnabled {
            if model.cloud.isAuthenticated {
                Button(L10n.text("上传暂存文件")) { model.uploadStoredFiles() }.buttonStyle(PulseButtonStyle())
                    .disabled(model.preview || model.uploads.isSyncing || model.uploads.pendingCount == 0)
            } else {
                Button(L10n.text("连接账户")) { model.openSettings(.account) }.buttonStyle(PulseButtonStyle())
            }
        }
    }
    @ViewBuilder private var fileActions: some View {
        Button(L10n.text("导入原始 FIT")) { model.importFIT() }.disabled(model.preview)
        Button(L10n.text("同步 FIT 文件夹")) { model.watchFITFolder() }.disabled(model.preview)
    }
}

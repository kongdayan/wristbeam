import SwiftUI

private struct StorageFooterSizeKey: PreferenceKey {
    static let defaultValue = CGSize.zero
    static func reduce(value: inout CGSize, nextValue: () -> CGSize) {
        let next = nextValue()
        if next != .zero { value = next }
    }
}

struct LocalStorageSheet: View {
    @ObservedObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var plan: LocalStoragePlan?
    @State private var checking = false
    @State private var removeFIT = true
    @State private var compactLogs = false
    @State private var confirmClearHistory = false
    @State private var message = ""
    @State private var finished = false
    @State private var inspectedScope = ""
    var onFooterLayout: ((CGSize) -> Void)?
    init(model: AppModel, previewPlan: LocalStoragePlan? = nil, previewMessage: String? = nil, previewFinished: Bool = false,
         onFooterLayout: ((CGSize) -> Void)? = nil) {
        precondition(PulseRuntime.isPreview || (previewPlan == nil && previewMessage == nil && !previewFinished))
        self.model = model
        _plan = State(initialValue:previewPlan)
        _removeFIT = State(initialValue:previewPlan?.fitFiles.isEmpty != true)
        _message = State(initialValue:previewMessage ?? "")
        _finished = State(initialValue:previewFinished)
        self.onFooterLayout = onFooterLayout
    }
    private var selectedBytes: Int64 {
        guard let plan else { return 0 }
        return (removeFIT ? plan.fitBytes : 0) + (compactLogs ? plan.journalSavings : 0)
    }
    private func size(_ bytes: Int64) -> String { bytes == 0 ? "0 KB" : ByteCountFormatter.string(fromByteCount:bytes,countStyle:.file) }
    var body: some View {
        VStack(alignment:.leading,spacing:16) {
            Text(L10n.text("清理本地数据")).font(PulseTheme.font(size:20,weight:.semibold))
            ScrollView {
                VStack(alignment:.leading,spacing:18) {
                    if checking {
                        HStack { ProgressView().controlSize(.small); Text(L10n.text("正在检查本地文件…")) }
                    }
                    if let plan, !finished {
                        VStack(alignment:.leading,spacing:8) {
                            Text(L10n.text("清理所选副本")).font(PulseTheme.font(size:14,weight:.semibold))
                            Toggle(isOn:$removeFIT) {
                                Text(L10n.format("已上传 FIT 副本 · {0} 份 · {1}",String(plan.fitFiles.count),size(plan.fitBytes)))
                            }.toggleStyle(.checkbox).disabled(plan.fitFiles.isEmpty)
                            Text(L10n.text("仅清理当前账户已确认上传的副本，保留账户、上传记录和手表文件。"))
                                .foregroundStyle(Color.primary.opacity(0.72))
                            if !plan.journals.isEmpty {
                                Toggle(isOn:$compactLogs) {
                                    Text(L10n.format("精简旧日志 · 可减少约 {0}",size(plan.journalSavings)))
                                }.toggleStyle(.checkbox)
                                Text(L10n.text("保留手表历史读数，仅处理今天以前的冗余记录。"))
                                    .foregroundStyle(Color.primary.opacity(0.72))
                            } else {
                                Text(L10n.text("旧日志已精简，无需处理。"))
                                    .foregroundStyle(Color.primary.opacity(0.72))
                            }
                            if plan.protectedJobs > 0 {
                                Text(L10n.format("{0} 份尚未确认上传，将保留。",String(plan.protectedJobs)))
                                    .foregroundStyle(Color.primary.opacity(0.72))
                            }
                            if plan.protectedFiles > 0 {
                                Text(L10n.format("另有 {0} 个文件无法安全处理，将保留。",String(plan.protectedFiles)))
                                    .foregroundStyle(PulseTheme.warning)
                            }
                        }
                        Divider()
                        VStack(alignment:.leading,spacing:8) {
                            Text(L10n.text("清空全部读数")).font(PulseTheme.font(size:14,weight:.semibold))
                            Text(L10n.format("读数日志占用 {0}。",size(plan.telemetryBytes)))
                            Text(L10n.text("包含今天的日志和所有账户的曲线缓存，之后继续记录新读数。保留当前指标、账户和 FIT。"))
                                .foregroundStyle(Color.primary.opacity(0.72))
                            Text(L10n.text("云端已有曲线可重新获取；逐条手表读数无法完整恢复。"))
                                .foregroundStyle(Color.primary.opacity(0.72))
                            Button(L10n.text("清空全部读数…"),role:.destructive) { confirmClearHistory = true }
                                .disabled(checking || model.hasActiveFileOperations || model.preview)
                        }
                    }
                    if !message.isEmpty { PulseNotice(text:message,warning:!finished) }
                }.frame(maxWidth:.infinity,alignment:.leading).padding(.trailing,8)
            }
            if model.isMaintainingLocalStorage {
                HStack { ProgressView().controlSize(.small); Text(L10n.text("正在处理，原文件会保留到废纸篓…")) }
            }
            Divider()
            Text(L10n.text("原文件移入废纸篓，清空废纸篓后才释放磁盘空间。"))
                .font(PulseTheme.font(size:12)).foregroundStyle(Color.primary.opacity(0.72))
            ViewThatFits(in:.horizontal) {
                HStack {
                    cancelButton
                    if !finished { recheckButton; Spacer(minLength:8); cleanupButton }
                }
                VStack(alignment:.leading,spacing:8) {
                    if !finished { cleanupButton }
                    HStack { cancelButton; if !finished { recheckButton } }
                }
            }
            .background(GeometryReader { proxy in Color.clear.preference(key:StorageFooterSizeKey.self,value:proxy.size) })
        }
        .padding(24).frame(width:560,height:560)
        .background(PulseTheme.background).preferredColorScheme(model.preferredColorScheme)
        .font(PulseTheme.font(size:12)).environment(\.locale,L10n.locale)
        .interactiveDismissDisabled(model.isMaintainingLocalStorage)
        .onPreferenceChange(StorageFooterSizeKey.self) { onFooterLayout?($0) }
        .alert(L10n.text("清空全部本地读数历史？"),isPresented:$confirmClearHistory) {
            Button(L10n.text("取消"),role:.cancel) { }
            Button(L10n.text("清空历史"),role:.destructive) { clearHistory() }
        } message: {
            Text(L10n.text("包含今天的日志及所有账户的曲线缓存。原文件移入废纸篓；仅云端已有的曲线可以重新下载。当前指标、FIT 和账户不受影响。"))
        }
        .task { if !(model.preview && plan != nil) { await inspect() } }
    }
    private var cancelButton: some View {
        Button(L10n.text(finished ? "完成" : "取消")) { dismiss() }.keyboardShortcut(.cancelAction)
            .disabled(model.isMaintainingLocalStorage)
    }
    private var recheckButton: some View {
        Button(L10n.text("重新检查")) { Task { await inspect() } }.disabled(checking || model.isMaintainingLocalStorage)
    }
    private var cleanupButton: some View {
        Button(L10n.format("清理所选副本 · {0}",size(selectedBytes))) { perform() }
            .buttonStyle(.bordered)
            .disabled(checking || selectedBytes == 0 || model.hasActiveFileOperations || model.preview)
    }
    @MainActor private func inspect() async {
        guard !checking else { return }
        checking = true; message = ""; plan = nil
        defer { checking = false }
        let region = model.cloud.region, account = model.cloud.accountGUID, root = AppPaths.root
        do {
            let result = try await Task.detached(priority:.utility) { try LocalStorageMaintenance.inspect(root:root,region:region,account:account) }.value
            guard model.cloud.region == region, model.cloud.accountGUID == account else { throw LocalStorageMaintenance.Failure.changed }
            plan = result
            if result.fitFiles.isEmpty { removeFIT = false }
            model.localStorageReview = ["confirmedJobs":Int64(result.confirmedJobs),"unconfirmedJobs":Int64(result.protectedJobs),
                "fitCopies":Int64(result.fitFiles.count),"fitBytes":result.fitBytes,"journalDays":Int64(result.journals.count),
                "journalSavings":result.journalSavings,"telemetryBytes":result.telemetryBytes,"protectedFiles":Int64(result.protectedFiles)]
            inspectedScope = region.rawValue + ":" + account
        } catch { message = (error as? LocalStorageMaintenance.Failure).map { L10n.text($0.localizedDescription) } ?? L10n.text("检查未完成，原始文件保留。") }
    }
    @MainActor private func perform() {
        guard let plan, !model.preview, !model.hasActiveFileOperations else { return }
        guard inspectedScope == model.cloud.region.rawValue + ":" + model.cloud.accountGUID else {
            message = L10n.text(LocalStorageMaintenance.Failure.changed.localizedDescription); self.plan = nil; return
        }
        let fits = removeFIT, logs = compactLogs
        model.isMaintainingLocalStorage = true; model.uploads.storageMaintenanceActive = true; message = ""
        Task {
            defer { model.isMaintainingLocalStorage = false; model.uploads.storageMaintenanceActive = false; model.refreshLocalDataSummary() }
            do {
                let result = try await Task.detached(priority:.utility) { try LocalStorageMaintenance.execute(plan,removeFIT:fits,compactLogs:logs) }.value
                finished = true
                message = L10n.format("已移走 {0} 份 FIT 副本，精简 {1} 天日志。应用目录减少 {2}，原文件保留在废纸篓。",String(result.originals),String(result.compacted),size(result.appBytesReduced))
            } catch { message = (error as? LocalStorageMaintenance.Failure).map { L10n.text($0.localizedDescription) } ?? L10n.text("清理未完成，原数据已保留或恢复，请重新检查。") }
        }
    }
    @MainActor private func clearHistory() {
        guard !model.preview, !model.hasActiveFileOperations else { return }
        message = ""
        Task {
            do {
                let bytes = try await model.clearLocalReadingHistory()
                finished = true
                message = L10n.format("已清空本地读数历史，应用目录减少 {0}。新读数继续记录；原文件保留在废纸篓。",size(bytes))
            } catch {
                message = (error as? LocalStorageMaintenance.Failure).map { L10n.text($0.localizedDescription) } ?? L10n.text("清理未完成，原数据已保留或恢复，请重新检查。")
            }
        }
    }
}

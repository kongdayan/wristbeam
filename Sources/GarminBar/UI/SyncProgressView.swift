import SwiftUI

struct SyncProgressView: View {
    @ObservedObject var model: AppModel
    private var jobs: [GarminUploadJob] { model.uploads.visibleJobs }
    var body: some View {
        PulseCard {
            VStack(alignment: .leading, spacing: 12) {
                Text(L10n.text("同步进度")).font(PulseTheme.font(size: 17, weight: .semibold))
                row("最近接收", date(model.lastReceivedAt), "antenna.radiowaves.left.and.right")
                row("本地已保存", date(model.lastLocalSavedAt), "externaldrive")
                row("等待上传", String(jobs.filter { !$0.state.isComplete }.count), "arrow.up.circle")
                row("云端已确认", String(jobs.filter { $0.state == .accepted || $0.state == .duplicate }.count), "checkmark.icloud")
                let retry = jobs.filter { !$0.state.isComplete && $0.attempts > 0 }
                if !retry.isEmpty {
                    row("等待重试", String(retry.count), "arrow.clockwise")
                    Button(L10n.text("重试上传")) { model.uploadStoredFiles() }.buttonStyle(.bordered)
                }
                if !model.storageIssues.isEmpty {
                    Label(L10n.text("本地保存或读取异常"), systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
                    Button(L10n.text("重试本地存储")) { model.retryLocalStorage() }.buttonStyle(.bordered)
                }
            }
        }
    }
    private func date(_ value: Date?) -> String { value?.formatted(.dateTime.month().day().hour().minute().locale(L10n.locale)) ?? "—" }
    private func row(_ label: String, _ value: String, _ symbol: String) -> some View {
        HStack { Label(L10n.text(label), systemImage: symbol); Spacer(); Text(value).monospacedDigit() }
            .font(PulseTheme.font(size: 12))
    }
}

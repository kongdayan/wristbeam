import SwiftUI

struct SyncProgressView: View {
    @ObservedObject var model: AppModel
    var body: some View {
        PulseCard {
            VStack(alignment: .leading, spacing: 14) {
                Text(L10n.text("数据流向")).font(PulseTheme.font(size: 17, weight: .semibold))
                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .top, spacing: 12) {
                        watch; Image(systemName: "arrow.right").foregroundStyle(PulseTheme.secondary)
                        local; Image(systemName: "arrow.right").foregroundStyle(PulseTheme.secondary)
                        cloud
                    }.fixedSize(horizontal: true, vertical: false)
                    VStack(alignment: .leading, spacing: 14) { watch; local; cloud }
                }
            }
        }
    }
    private var watch: some View { stage("手表", model.workflow.connectionTitle, date(model.lastReceivedAt), "applewatch", model.bluetooth.isConnected) }
    private var local: some View { stage("本地", model.workflow.storageTitle, date(model.lastLocalSavedAt), "externaldrive", model.workflow.hasLocalData && !model.workflow.storageFailed) }
    private var cloud: some View {
        stage("云端", model.cloudSyncEnabled ? model.workflow.accountTitle : "未启用", model.cloudSyncEnabled ? model.workflow.transferTitle : "仅本地", "cloud", model.workflow.cloudActive)
    }
    private func date(_ value: Date?) -> String { value?.formatted(.dateTime.month().day().hour().minute().locale(L10n.locale)) ?? "—" }
    private func stage(_ title: String, _ status: String, _ detail: String, _ symbol: String, _ active: Bool) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(L10n.text(title), systemImage: symbol).font(PulseTheme.font(size: 14, weight: .semibold)).foregroundStyle(active ? PulseTheme.mint : PulseTheme.secondary)
            Text(L10n.text(status)).font(PulseTheme.font(size: 12))
            Text(L10n.text(detail)).font(PulseTheme.font(size: 11)).foregroundStyle(PulseTheme.secondary)
        }.frame(minWidth: 140, alignment: .leading).accessibilityElement(children: .combine)
    }
}

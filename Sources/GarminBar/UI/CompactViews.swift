import SwiftUI

struct MenuPopover: View {
    @ObservedObject var model: AppModel
    var body: some View {
        VStack(alignment: .leading, spacing: 13) {
            HStack {
                Image(systemName: "waveform.path.ecg").foregroundStyle(PulseTheme.mint).font(PulseTheme.font(size: 20))
                VStack(alignment: .leading, spacing: 3) {
                    Text(L10n.text("腕映")).font(PulseTheme.font(size: 15, weight: .semibold))
                    Text(L10n.text(model.preview ? "演示预览" : model.bluetooth.connectedName)).font(PulseTheme.font(size: 10)).foregroundStyle(PulseTheme.secondary)
                }
                Spacer()
                StatusDot(active: model.bluetooth.isConnected || model.preview)
            }
            ScrollView {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 2), spacing: 8) {
                    ForEach(model.menuVisibleMetrics) { MetricCard(model: model, kind: $0, compact: true) }
                }
                if model.menuVisibleMetrics.isEmpty { Text(L10n.text("在显示设置中选择菜单栏指标")).font(PulseTheme.font(size: 11)).foregroundStyle(PulseTheme.secondary) }
            }.frame(maxHeight: .infinity)
            VStack(alignment: .leading, spacing: 9) {
                HStack { Image(systemName: "antenna.radiowaves.left.and.right"); Text(L10n.text(model.bluetooth.status)); Spacer() }
                HStack { Image(systemName: "cloud"); Text(L10n.text(model.cloud.isAuthenticated ? "\(model.cloud.region.title)已连接" : "\(model.cloud.region.title)待登录")); Spacer(); Text(L10n.text("\(model.uploads.pendingCount) 待同步")) }
            }.font(PulseTheme.font(size: 10)).foregroundStyle(PulseTheme.secondary)
            HStack(spacing: 9) {
                Button { model.openSettings(.watch) } label: { Label(L10n.text("连接与配置"), systemImage: "slider.horizontal.3").frame(maxWidth: .infinity) }
                    .buttonStyle(.borderedProminent).tint(PulseTheme.mint).foregroundStyle(PulseTheme.onAccent)
                Button { model.floatingEnabled.toggle() } label: { Image(systemName: model.floatingEnabled ? "rectangle.slash" : "rectangle.on.rectangle") }.help(L10n.text("显示或隐藏浮动窗口"))
                    .buttonStyle(.bordered)
            }.controlSize(.regular)
            HStack {
                Button(L10n.text("立即同步")) { model.syncNow() }.disabled(model.preview || (!model.bluetooth.canSyncFiles && model.uploads.pendingCount == 0))
                Spacer()
                Button(L10n.text("退出")) { model.onQuit?() }
            }.buttonStyle(.plain).font(PulseTheme.font(size: 10)).foregroundStyle(PulseTheme.secondary)
        }
        .id(model.language).padding(20).frame(width: 420, height: 500).background(PulseTheme.background).preferredColorScheme(model.preferredColorScheme).environment(\.locale, L10n.locale)
    }
}

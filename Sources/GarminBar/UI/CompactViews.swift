import SwiftUI

struct MenuPopover: View {
    @ObservedObject var model: AppModel
    var body: some View {
        VStack(alignment: .leading, spacing: 13) {
            HStack {
                Image(systemName: "waveform.path.ecg").foregroundStyle(PulseTheme.mint).font(PulseTheme.font(size: 20))
                VStack(alignment: .leading, spacing: 3) {
                    Text(L10n.text("Garmin Pulse")).font(PulseTheme.font(size: 15, weight: .semibold))
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

struct FloatingPulseView: View {
    @ObservedObject var model: AppModel
    var body: some View {
        VStack(spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: "waveform.path.ecg").font(PulseTheme.font(size: 11)).foregroundStyle(PulseTheme.mint)
                Text(L10n.text("GARMIN PULSE")).font(PulseTheme.font(size: 9, weight: .semibold)).tracking(1.4)
                Spacer()
                StatusDot(active: model.bluetooth.isConnected || model.preview)
                Text(L10n.text(model.preview ? "DEMO" : model.bluetooth.isConnected ? "LIVE" : "OFFLINE")).font(PulseTheme.font(size: 8, weight: .medium)).foregroundStyle(PulseTheme.secondary)
                Button { model.floatingEnabled = false } label: { Image(systemName: "xmark").font(PulseTheme.font(size: 12)).frame(width: 30, height: 30) }.buttonStyle(.plain).foregroundStyle(PulseTheme.secondary)
            }
            ScrollView {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 12), count: model.floatingColumns), alignment: .leading, spacing: 14) {
                    ForEach(model.visibleMetrics) { kind in
                        Button { model.openMetric(kind) } label: {
                        VStack(alignment: .leading, spacing: 5) {
                            HStack(spacing: 4) {
                                Image(systemName: kind.symbol).foregroundStyle(PulseTheme.color(kind))
                                Text(L10n.text(kind.title.components(separatedBy: "（").first ?? kind.title)).foregroundStyle(PulseTheme.secondary).lineLimit(1)
                            }.font(PulseTheme.font(size: 12))
                            Text(L10n.text(model.display(kind))).font(PulseTheme.font(size: 28, weight: .medium, design: .rounded)).monospacedDigit().lineLimit(1).minimumScaleFactor(0.6)
                            if let timeline = kind.timelineKind {
                                MetricMiniChart(series: model.series(for: kind), kind: timeline).equatable().frame(height: 45)
                            } else {
                                Text(L10n.text("当日汇总")).font(PulseTheme.font(size: 8)).foregroundStyle(PulseTheme.secondary).frame(height: 34, alignment: .bottom)
                            }
                            let origin = model.metrics[kind]?.origin
                            Text(L10n.text("\(kind.unit) · \(origin == .estimated ? "估算" : origin == .cloud ? "同步" : origin == .watch ? "实时" : "待更新")")).font(PulseTheme.font(size: 8)).foregroundStyle(PulseTheme.secondary)
                        }.frame(maxWidth: .infinity, minHeight: 132 * model.fontScale, alignment: .topLeading)
                        }.buttonStyle(.plain).help(L10n.text("\(model.detail(kind)) · 点击查看详细记录"))
                    }
                }
                if model.visibleMetrics.isEmpty { Text(L10n.text("在显示设置中选择指标")).font(PulseTheme.font(size: 12)).foregroundStyle(PulseTheme.secondary) }
            }
            HStack {
                Text(L10n.text(model.cloud.isAuthenticated ? "\(model.cloud.region.title) · 点击曲线查看详情" : "本地实时数据 · 点击查看详情")).font(PulseTheme.font(size: 8)).foregroundStyle(PulseTheme.secondary)
                Spacer()
                Button { model.openSettings(.overview) } label: { Image(systemName: "arrow.up.right").font(PulseTheme.font(size: 14)).frame(width: 32, height: 32) }.buttonStyle(.plain).foregroundStyle(PulseTheme.secondary).help(L10n.text("打开健康看板"))
            }
        }.id(model.language).padding(18).frame(width: model.floatingWidth, height: model.floatingHeight).environment(\.locale, L10n.locale)
            .background(PulseTheme.background.opacity(0.96))
            .clipShape(RoundedRectangle(cornerRadius: 19))
            .overlay(RoundedRectangle(cornerRadius: 19).stroke(Color.primary.opacity(0.12), lineWidth: 1))
            .preferredColorScheme(model.preferredColorScheme)
    }
}

import SwiftUI

private let menuSecondary = Color.primary.opacity(0.72)

/// Route Escape through AppKit's responder chain as well as SwiftUI commands.
final class PulseMenuHostingController: NSHostingController<MenuPopover> {
    var dismissMenu: () -> Void = {}
    override func cancelOperation(_ sender: Any?) { dismissMenu() }
}

private struct MenuBoundsKey: PreferenceKey {
    static let defaultValue: [String: CGRect] = [:]
    static func reduce(value: inout [String: CGRect], nextValue: () -> [String: CGRect]) {
        value.merge(nextValue(), uniquingKeysWith: { _, new in new })
    }
}
private func menuBounds(_ name: String) -> some View {
    GeometryReader { proxy in
        Color.clear.preference(key: MenuBoundsKey.self, value: [name: proxy.frame(in: .named("menu-content"))])
    }
}

/// A quick glance and a route into the main window; opening this view never starts a sync.
struct MenuPopover: View {
    @ObservedObject var model: AppModel
    var onLayout: (([String: CGRect]) -> Void)? = nil
    var onDismiss: () -> Void = {}
    private var selected: [MetricKind] {
        let preferred: [MetricKind] = [.bodyBattery, .heartRate, .stress, .steps]
        return (preferred + MetricKind.allCases.filter { !preferred.contains($0) })
            .filter { model.menuMetrics.contains($0) && !$0.isDeviceStatus }
    }
    private var width: CGFloat { 400 * min(1.2, max(1, model.fontScale)) }
    private var canReceiveFiles: Bool {
        !model.preview && !model.isMaintainingLocalStorage && model.bluetooth.canSyncFiles && !model.bluetooth.isTransferringFiles
            && !model.bluetooth.connectIQInstallBusy && !model.bluetooth.connectIQSettingsBusy
            && !model.bluetooth.watchFaceBusy && !model.bluetooth.watchFaceOpenBusy
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            Divider()
            if selected.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Text(L10n.text("选择你关心的指标")).font(PulseTheme.font(size: 14, weight: .medium))
                    Text(L10n.text("在菜单栏指标设置中选择要快速查看的数据。"))
                        .font(PulseTheme.font(size: 12)).foregroundStyle(menuSecondary)
                    Button(L10n.text("选择指标")) { model.openSettings(.metricSelection) }
                }.frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 10)
            } else {
                LazyVGrid(columns: [GridItem(.flexible(), spacing: 16), GridItem(.flexible(), spacing: 16)], alignment: .leading, spacing: 16) {
                    ForEach(Array(selected.prefix(4))) { kind in
                        MenuMetricReading(model: model, kind: kind).background(menuBounds("metric-" + kind.rawValue))
                    }
                }
                if selected.count > 4 {
                    Button(L10n.format("在看板查看其余 {0} 项", String(selected.count - 4))) { model.openSettings(.overview) }
                        .font(PulseTheme.font(size: 12)).buttonStyle(.link)
                }
            }
            Divider()
            operationStatus
            MenuIntegrationStatus(access: model.developer) { model.openSettings(.developer) }
            Divider()
            HStack(spacing: 12) {
                Button { model.openSettings(.overview) } label: {
                    Text(L10n.text("打开健康看板")).frame(maxWidth: .infinity)
                }.buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction).background(menuBounds("dashboard"))
                Button { model.floatingEnabled.toggle() } label: {
                    Label(L10n.text(model.floatingEnabled ? "隐藏浮窗" : "显示浮窗"),
                          systemImage: model.floatingEnabled ? "rectangle.slash" : "rectangle.on.rectangle")
                }.buttonStyle(.bordered).background(menuBounds("floating"))
                    .accessibilityValue(L10n.text(model.floatingEnabled ? "已开启" : "已关闭"))
            }.controlSize(.large).font(PulseTheme.font(size: 12, weight: .medium))
        }
        .padding(20).frame(width: width).fixedSize(horizontal: false, vertical: true)
        .background(PulseTheme.background)
        .preferredColorScheme(model.preferredColorScheme).environment(\.locale, L10n.locale)
        .background(menuBounds("content")).coordinateSpace(name: "menu-content")
        .onPreferenceChange(MenuBoundsKey.self) { onLayout?($0) }
        .onExitCommand(perform: onDismiss)
        .id(model.language)
    }
    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text(L10n.text("腕映")).font(PulseTheme.font(size: 17, weight: .semibold))
                if PulseRuntime.isDevelopmentBuild || model.preview {
                    Text(model.preview ? L10n.text("演示预览") : "Dev").font(.system(size: 10, weight: .semibold))
                        .padding(.horizontal, 5).padding(.vertical, 2)
                        .background(Color.primary.opacity(0.07), in: RoundedRectangle(cornerRadius: 4))
                        .accessibilityLabel(L10n.text("开发构建"))
                }
                Spacer()
                Menu {
                    Button(L10n.text("选择指标")) { model.openSettings(.metricSelection) }
                    Button(L10n.text("接收手表文件")) { model.syncNow() }.disabled(!canReceiveFiles)
                    Button(L10n.text("同步记录")) { model.openSettings(.sync) }
                    Divider()
                    Button(L10n.text("设置…")) { model.openSettings(model.settingsPage) }
                        .keyboardShortcut(",", modifiers: .command)
                    Button(L10n.text("退出腕映")) { model.onQuit?() }.keyboardShortcut("q", modifiers: .command)
                } label: { Image(systemName: "ellipsis.circle").font(.system(size: 17)).frame(width: 28, height: 28) }
                    .menuStyle(.borderlessButton).menuIndicator(.hidden).controlSize(.large).frame(width: 28, height: 28)
                    .help(L10n.text("更多操作")).accessibilityLabel(L10n.text("更多操作"))
                    .background(menuBounds("actions"))
            }
            HStack(spacing: 8) {
                Image(systemName: "applewatch").foregroundStyle(menuSecondary)
                Text(L10n.text(model.workflow.connectionTitle)).lineLimit(1)
                Spacer(minLength: 8)
                if model.bluetooth.isConnected { WatchBatteryBadge(model: model) }
                else {
                    Button(L10n.text("连接手表")) { model.openSettings(.watch) }
                        .buttonStyle(.bordered).disabled(model.bluetooth.isConnecting).background(menuBounds("connect"))
                }
            }.font(PulseTheme.font(size: 12))
        }
    }
    private var operationStatus: some View {
        Button { model.openSettings(.sync) } label: {
            HStack(alignment: .top, spacing: 9) {
                if model.bluetooth.isTransferringFiles || model.uploads.isSyncing { ProgressView().controlSize(.small) }
                else { Image(systemName: model.workflow.storageFailed ? "exclamationmark.triangle" : "externaldrive") }
                VStack(alignment: .leading, spacing: 3) {
                    Text(L10n.text(model.workflow.summary)).foregroundStyle(Color.primary)
                    if model.cloudSyncEnabled {
                        Text(L10n.text(model.workflow.accountTitle) + " · " + L10n.text(model.workflow.transferTitle)).foregroundStyle(menuSecondary)
                    } else { Text(L10n.text("仅本地")).foregroundStyle(menuSecondary) }
                }.fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
                Image(systemName: "chevron.right").font(.system(size: 10)).foregroundStyle(menuSecondary)
            }.font(PulseTheme.font(size: 12)).contentShape(Rectangle())
        }.buttonStyle(.plain).help(L10n.text("查看同步记录"))
    }
}

private struct MenuMetricReading: View {
    @ObservedObject var model: AppModel
    @State private var hovered = false
    let kind: MetricKind
    private var sample: MetricSample? {
        guard let sample = model.metrics[kind], sample.value.isFinite,
              sample.timestamp.timeIntervalSince(model.now) <= 60 else { return nil }
        return sample
    }
    private var value: String {
        guard let sample else { return "—" }
        if kind == .hrvStatus { return GarminHRVStatus(rawValue: Int(sample.value))?.title ?? "—" }
        return sample.formatted
    }
    private var stale: Bool { sample.map { model.freshness($0).stale } ?? true }
    private var source: String {
        guard let sample else { return L10n.text("暂无记录") }
        switch sample.origin {
        case .watch: return L10n.text("手表")
        case .cloud: return L10n.text("云端")
        case .estimated: return L10n.text("估算")
        }
    }
    private var recordedAt: String {
        guard let sample else { return L10n.text("等待接收数据") }
        let time = sample.timestamp.formatted(Date.FormatStyle(date: .omitted, time: .shortened).locale(L10n.locale))
        if sample.timestampIsMeasurement == false {
            let updated = Calendar.current.isDate(sample.timestamp, inSameDayAs: model.now)
                ? time : sample.timestamp.formatted(.dateTime.month().day().hour().minute().locale(L10n.locale))
            return L10n.format("同步于 {0}", updated)
        }
        if Calendar.current.isDate(sample.timestamp, inSameDayAs: model.now) {
            let age = max(0, model.now.timeIntervalSince(sample.timestamp))
            if !stale, age < 60 { return L10n.text("刚刚") }
            if !stale, age < 3600 { return L10n.format("{0} 分钟前", String(max(1, Int(age / 60)))) }
            return stale ? L10n.format("上次 {0}", time) : time
        }
        return sample.timestamp.formatted(.dateTime.month().day().hour().minute().locale(L10n.locale))
    }
    var body: some View {
        Button { model.openMetric(kind, day: sample?.timestamp) } label: {
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 5) {
                    MetricIcon(kind: kind).foregroundStyle(PulseTheme.color(kind)).frame(width: 16, height: 16)
                    Text(kind.title).lineLimit(1)
                }.font(PulseTheme.font(size: 12, weight: .medium)).foregroundStyle(menuSecondary)
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Text(value).font(PulseTheme.font(size: 28, weight: .semibold)).monospacedDigit()
                        .lineLimit(1).minimumScaleFactor(0.65)
                    if sample != nil { Text(kind.unit).font(PulseTheme.font(size: 11)).foregroundStyle(menuSecondary) }
                }.frame(height: 38 * min(1.6, max(1, model.fontScale)), alignment: .leading)
                HStack(spacing: 4) {
                    Text(kind == .steps && sample != nil ? source + " · " + L10n.text("今日累计") : source)
                    if sample != nil, stale { Text(L10n.text("旧读数")).foregroundStyle(Color.primary) }
                }.font(PulseTheme.font(size: 11)).foregroundStyle(menuSecondary).lineLimit(1)
                Text(recordedAt).font(PulseTheme.font(size: 11)).foregroundStyle(menuSecondary).lineLimit(1)
            }.padding(6).frame(maxWidth: .infinity, alignment: .leading)
                .background(hovered ? Color.primary.opacity(0.05) : Color.clear, in: RoundedRectangle(cornerRadius: 6))
                .contentShape(Rectangle())
        }.buttonStyle(.plain).help(model.detail(kind))
            .onHover { hovered = $0 }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("\(kind.title), \(value) \(kind.unit), \(source), \(sample != nil && stale ? L10n.text("旧读数") : ""), \(recordedAt)")
            .accessibilityHint(L10n.text("打开指标详情"))
    }
}

private struct MenuIntegrationStatus: View {
    @ObservedObject var access: DeveloperAccess
    let open: () -> Void
    var body: some View {
        if access.configuration.enabled || access.running {
            Button(action: open) {
                HStack(spacing: 9) {
                    Image(systemName: access.running ? "point.3.connected.trianglepath.dotted" : "exclamationmark.circle")
                    Text(L10n.text(access.running ? "MCP 已启用" : "MCP 未运行"))
                    Spacer()
                    Image(systemName: "chevron.right").font(.system(size: 10))
                }.font(PulseTheme.font(size: 12)).foregroundStyle(menuSecondary).contentShape(Rectangle())
            }.buttonStyle(.plain).help(L10n.text("开发者集成"))
        }
    }
}

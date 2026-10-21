import SwiftUI

struct WatchBatteryBadge: View {
    @ObservedObject var model: AppModel
    private var sample: MetricSample? {
        guard let sample = model.metrics[.watchBattery], sample.value.isFinite, (0...100).contains(sample.value) else { return nil }
        return sample
    }
    private func symbol(_ percent: Int) -> String {
        if model.bluetooth.batteryCharging == true { return "battery.100percent.bolt" }
        if percent <= 10 { return "battery.0percent" }
        if percent <= 30 { return "battery.25percent" }
        if percent <= 55 { return "battery.50percent" }
        if percent <= 80 { return "battery.75percent" }
        return "battery.100percent"
    }
    var body: some View {
        if let sample {
            let percent = Int(sample.value.rounded())
            HStack(spacing: 4) {
                Image(systemName: symbol(percent))
                    .foregroundStyle(model.isStale(.watchBattery) ? Color.secondary : percent <= 20 ? Color.orange : PulseTheme.mint)
                Text("\(percent)%").monospacedDigit()
            }.font(PulseTheme.font(size: 11, weight: .medium))
                .foregroundStyle(model.isStale(.watchBattery) ? Color.secondary : Color.primary)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(L10n.format("手表电量：{0}%", String(percent)))
                .help(L10n.format("上次更新：{0}", sample.timestamp.formatted(.dateTime.hour().minute().locale(L10n.locale))))
        }
    }
}

struct DashboardConnectionStatus: View {
    @ObservedObject var model: AppModel
    var body: some View {
        HStack(spacing: 4) {
            Button { model.page = .watch } label: {
                HStack(spacing: 7) {
                    Image(systemName: "applewatch")
                    Text(L10n.text(model.workflow.connectionTitle))
                    WatchBatteryBadge(model: model)
                    StatusDot(active: model.bluetooth.isConnected)
                }
            }.help(L10n.text(model.bluetooth.status))
            Divider().frame(height: 16).padding(.horizontal, 4)
            Button { model.page = .account } label: {
                HStack(spacing: 7) {
                    Image(systemName: model.workflow.accountSymbol)
                    Text(L10n.text(model.workflow.accountTitle))
                    StatusDot(active: model.workflow.cloudActive)
                }
            }.help(L10n.text(model.cloud.region.title))
        }.buttonStyle(.plain).font(PulseTheme.font(size: 11, weight: .medium))
            .padding(12).background(PulseTheme.surface, in: RoundedRectangle(cornerRadius: 13))
            .overlay(RoundedRectangle(cornerRadius: 13).stroke(Color.primary.opacity(0.07)))
    }
}

struct DashboardStylePanel: View {
    @ObservedObject var model: AppModel
    @State private var search = ""
    @State private var expanded = Set(MetricCategory.allCases)
    private var available: [MetricKind] {
        MetricKind.allCases.filter { model.availableMetricKinds.contains($0) && (search.isEmpty || $0.title.localizedCaseInsensitiveContains(search)) }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(L10n.text("显示样式")).font(PulseTheme.font(size: 18, weight: .semibold))
            Picker(L10n.text("每行"), selection: $model.dashboardColumns) {
                Text(L10n.text("自动适应")).tag(0)
                ForEach(1...4, id: \.self) { Text(L10n.text("\($0) 张卡片")).tag($0) }
            }
            Picker(L10n.text("卡片"), selection: $model.cardSize) {
                ForEach(PulseCardSize.allCases) { Text(L10n.text($0.title)).tag($0) }
            }.pickerStyle(.segmented)
            Toggle(L10n.text("按类别分组"), isOn: $model.dashboardGrouped).toggleStyle(.switch)
            Text(L10n.text("前三项为重点指标；其余按类别显示。关闭分组可自由排序。"))
                .font(PulseTheme.font(size: 11)).foregroundStyle(PulseTheme.secondary)
            Divider()
            HStack {
                Text(L10n.text("看板指标")).font(PulseTheme.font(size: 13, weight: .semibold))
                Spacer()
                Text("\(model.dashboardVisibleMetrics.count) / \(model.availableMetricKinds.count)").foregroundStyle(PulseTheme.secondary)
            }
            HStack {
                Button(L10n.text("全选")) { model.dashboardMetrics.formUnion(model.availableMetricKinds) }
                Button(L10n.text("基础选择")) { model.dashboardMetrics = DashboardSharing.basicMetrics.intersection(model.availableMetricKinds) }
                Button(L10n.text("全取消")) { model.dashboardMetrics = [] }
            }.buttonStyle(.bordered).controlSize(.small)
            TextField(L10n.text("搜索指标"), text: $search).textFieldStyle(.roundedBorder)
            ScrollView {
                VStack(spacing: 6) {
                    ForEach(MetricCategory.allCases) { category in
                        let items = available.filter { $0.category == category }
                        if !items.isEmpty {
                            VStack(spacing: 5) {
                                HStack {
                                    Button {
                                        if expanded.contains(category) { expanded.remove(category) } else { expanded.insert(category) }
                                    } label: {
                                        HStack {
                                            Image(systemName: expanded.contains(category) ? "chevron.down" : "chevron.right").frame(width: 14)
                                            Text(category.title); Spacer()
                                        }.contentShape(Rectangle())
                                    }.buttonStyle(.plain)
                                    Button(L10n.text(items.allSatisfy { model.dashboardMetrics.contains($0) } ? "全取消" : "全选")) {
                                        model.select(items, enabled: !items.allSatisfy { model.dashboardMetrics.contains($0) }, destination: .dashboard)
                                    }.buttonStyle(.borderless)
                                }.font(PulseTheme.font(size: 12, weight: .semibold)).padding(.vertical, 7)
                                if expanded.contains(category) || !search.isEmpty {
                                    ForEach(items) { kind in
                                        Button {
                                            if model.dashboardMetrics.contains(kind) { model.dashboardMetrics.remove(kind) } else { model.dashboardMetrics.insert(kind) }
                                        } label: {
                                            HStack(spacing: 9) {
                                                Image(systemName: model.dashboardMetrics.contains(kind) ? "checkmark.square.fill" : "square").foregroundStyle(PulseTheme.mint)
                                                MetricIcon(kind: kind).foregroundStyle(PulseTheme.color(kind)).frame(width: 19)
                                                Text(kind.title); Spacer()
                                            }.padding(.vertical, 6).contentShape(Rectangle())
                                        }.buttonStyle(.plain).accessibilityValue(L10n.text(model.dashboardMetrics.contains(kind) ? "已选择" : "未选择"))
                                    }
                                }
                            }
                        }
                    }
                }
            }.frame(height: 270)
            Text(L10n.text("拖动卡片调整顺序；点击卡片进入全天图表和原始时间记录。"))
                .font(PulseTheme.font(size: 11)).foregroundStyle(PulseTheme.secondary)
            Divider()
            HStack {
                Text(L10n.text("刷新同步指标")).font(PulseTheme.font(size: 12))
                Spacer()
                Button { model.refreshMetricsNow() } label: { Image(systemName: "arrow.clockwise") }
                    .disabled(model.preview || model.isRefreshingHealth).accessibilityLabel(L10n.text("刷新同步指标"))
            }
        }.padding(22).frame(width: 370).background(PulseTheme.background)
            .preferredColorScheme(model.preferredColorScheme)
    }
}

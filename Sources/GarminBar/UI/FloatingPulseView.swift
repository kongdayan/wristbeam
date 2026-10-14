import SwiftUI

struct FloatingPulseView: View {
    @ObservedObject var model: AppModel
    @State private var selected: MetricKind?
    private var kind: MetricKind? { selected.flatMap { model.visibleMetrics.contains($0) ? $0 : nil } ?? model.visibleMetrics.first }
    var body: some View {
        VStack(alignment:.leading,spacing:14) {
            HStack {
                Image(systemName:"waveform.path.ecg").foregroundStyle(PulseTheme.mint)
                Text(L10n.text("腕映")).font(PulseTheme.font(size:12,weight:.semibold))
                Spacer()
                Picker(L10n.text("显示方式"),selection:$model.floatingDetailed) {
                    Text(L10n.text("紧凑")).tag(false); Text(L10n.text("详细")).tag(true)
                }.labelsHidden().pickerStyle(.segmented).frame(width:145 * min(1.2,model.fontScale)).controlSize(.small)
                Button { model.floatingEnabled = false } label: { Image(systemName:"xmark").frame(width:24,height:24) }.buttonStyle(.plain).help(L10n.text("隐藏浮窗"))
            }
            ScrollView(.horizontal,showsIndicators:false) {
                HStack(spacing:9) {
                    ForEach(model.visibleMetrics) { metric in
                        Button { selected = metric } label: {
                            HStack(spacing:6) {
                                MetricIcon(kind:metric,size:16)
                                Text(L10n.text(model.display(metric))).font(PulseTheme.font(size:12,weight:.semibold,design:.rounded)).monospacedDigit()
                            }.padding(.horizontal,11).padding(.vertical,10)
                                .foregroundStyle(kind == metric ? PulseTheme.color(metric) : PulseTheme.secondary)
                                .background(kind == metric ? PulseTheme.color(metric).opacity(0.13) : Color.primary.opacity(0.04))
                                .clipShape(Capsule())
                        }.buttonStyle(.plain).accessibilityLabel(L10n.text(metric.title)).help(L10n.text(metric.title))
                    }
                }
            }.fixedSize(horizontal:false,vertical:true)
            if let kind {
                Button { model.openMetric(kind) } label: {
                    FloatingReading(model:model,kind:kind,detailed:model.floatingDetailed)
                }.buttonStyle(.plain).accessibilityLabel(L10n.text(kind.title) + " · " + L10n.text("查看详情"))
            } else {
                Text(L10n.text("在显示设置中选择指标")).foregroundStyle(PulseTheme.secondary).frame(maxWidth:.infinity,maxHeight:.infinity)
            }
            Spacer(minLength:0)
            HStack {
                StatusDot(active:model.preview || model.bluetooth.isConnected)
                Text(L10n.text(model.preview ? "演示数据" : model.bluetooth.isConnected ? "手表已连接" : "等待手表"))
                Spacer()
                Button { if let kind { model.openMetric(kind) } else { model.openSettings(.overview) } } label: {
                    Label(L10n.text("查看详情"),systemImage:"arrow.up.right")
                }.buttonStyle(.plain)
            }.font(PulseTheme.font(size:10)).foregroundStyle(PulseTheme.secondary)
        }.padding(18).frame(width:model.floatingWidth,height:model.floatingHeight)
            .background(PulseTheme.background.opacity(0.98))
            .clipShape(RoundedRectangle(cornerRadius:24))
            .overlay(RoundedRectangle(cornerRadius:24).strokeBorder(.primary.opacity(0.12)).allowsHitTesting(false))
            .preferredColorScheme(model.preferredColorScheme).environment(\.locale,L10n.locale)
    }
}

private struct FloatingReading: View {
    @ObservedObject var model: AppModel
    let kind: MetricKind
    let detailed: Bool
    private var series: MetricDaySeries? { model.series(for:kind) }
    private var progress: Double? {
        guard let value = model.metrics[kind]?.value else { return nil }
        if ["bodyBattery","stress","spo2"].contains(kind.rawValue) { return min(1,max(0,value / 100)) }
        if kind == .steps, let goal = model.metrics[MetricKind(rawValue:"daily.dailyStepGoal")!]?.value, goal > 0 { return min(1,max(0,value / goal)) }
        return nil
    }
    var body: some View {
        VStack(alignment:.leading,spacing:12) {
            HStack {
                MetricIcon(kind:kind,size:19).foregroundStyle(PulseTheme.color(kind))
                Text(L10n.text(kind.title)).font(PulseTheme.font(size:14,weight:.semibold)).lineLimit(1)
                Spacer(minLength:2)
                if let sample = model.metrics[kind] {
                    Text(sample.timestamp,format:kind.isOvernightHRV ? .dateTime.month().day() : .dateTime.hour().minute())
                        .font(PulseTheme.font(size:10)).foregroundStyle(PulseTheme.secondary)
                }
            }
            HStack(alignment:.firstTextBaseline,spacing:7) {
                Text(L10n.text(model.display(kind))).font(PulseTheme.font(size:32,weight:.semibold,design:.rounded)).monospacedDigit().lineLimit(1).minimumScaleFactor(0.65)
                Text(L10n.text(kind.unit)).font(PulseTheme.font(size:11)).foregroundStyle(PulseTheme.secondary)
                Spacer()
                if model.isStale(kind) { Text(L10n.text("已过期")).font(PulseTheme.font(size:10)).foregroundStyle(.orange) }
            }
            if let progress {
                GeometryReader { geometry in
                    Capsule().fill(.primary.opacity(0.08))
                    Capsule().fill(PulseTheme.color(kind)).frame(width:geometry.size.width * progress)
                }.frame(height:6)
            }
            if detailed {
                Divider().padding(.vertical,2)
                HStack { Text(L10n.text(kind.isOvernightHRV ? "夜间 HRV 与恢复趋势" : "全天趋势")); Spacer() }
                    .font(PulseTheme.font(size:11,weight:.medium)).foregroundStyle(PulseTheme.secondary)
                if kind.isOvernightHRV {
                    if kind == .hrvStatus {
                        Text(L10n.text(model.detail(kind))).font(PulseTheme.font(size:11)).foregroundStyle(PulseTheme.secondary).frame(maxWidth:.infinity,minHeight:90,alignment:.topLeading)
                    } else { HRVTrendMiniChart(series:series).frame(height:95) }
                } else if let canonical = kind.timelineKind {
                    MetricMiniChart(series:series,kind:canonical).equatable().frame(height:95)
                } else {
                    Text(L10n.text("当日汇总")).foregroundStyle(PulseTheme.secondary).frame(maxWidth:.infinity,minHeight:95)
                }
                if let series, !series.values.isEmpty, series.kind.seriesStyle != .bars, kind != .hrvStatus {
                    HStack {
                        statistic("最低",value:series.minimum)
                        Spacer(); statistic("平均",value:series.mean)
                        Spacer(); statistic("最高",value:series.maximum)
                    }
                }
            }
        }.padding(16).frame(maxWidth:.infinity,alignment:.leading)
            .background(PulseTheme.surface).clipShape(RoundedRectangle(cornerRadius:17))
            .help(L10n.text(model.detail(kind)))
    }
    private func statistic(_ title: String, value: Double?) -> some View {
        VStack(alignment:.leading,spacing:4) {
            Text(L10n.text(title)).font(PulseTheme.font(size:10)).foregroundStyle(PulseTheme.secondary)
            Text(value.map { $0.formatted(.number.precision(.fractionLength(0...1))) } ?? "—").font(PulseTheme.font(size:14,weight:.semibold,design:.rounded)).monospacedDigit()
        }
    }
}

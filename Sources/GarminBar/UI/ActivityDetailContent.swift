import SwiftUI
import Charts

struct ActivityDetailContent: View {
    let summary: GarminActivity
    let detail: GarminActivityDetail?
    var body: some View {
        LazyVStack(alignment: .leading, spacing: 18) {
            ActivityHighlights(statistics: summary.statistics)
            if let detail {
                if !ActivityMetricCatalog.visibleCharts(detail).isEmpty { ActivityChartsSection(detail: detail) }
                ActivityZonesSection(detail: detail)
                ActivityLapsSection(detail: detail)
            }
            ActivityStatisticsSection(statistics: summary.statistics)
        }
    }
}

private struct ActivityHighlights: View {
    let statistics: [String: Double]
    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 140), spacing: 12)], spacing: 12) {
            ForEach(ActivityMetricCatalog.highlights(statistics)) { field in
                VStack(alignment: .leading, spacing: 8) {
                    Text(L10n.text(field.label)).font(PulseTheme.font(size: 12)).foregroundStyle(PulseTheme.secondary)
                    Text(field.formatted(statistics[field.key]!))
                        .font(PulseTheme.font(size: 23, weight: .semibold)).monospacedDigit().lineLimit(1).minimumScaleFactor(0.8)
                }.frame(maxWidth: .infinity, alignment: .leading).padding(16)
                    .background(PulseTheme.mint.opacity(0.07), in: RoundedRectangle(cornerRadius: 14))
            }
        }
    }
}

struct ActivityStatisticsSection: View {
    let statistics: [String: Double]
    @State private var expanded: Bool
    init(statistics: [String: Double], initiallyExpanded: Bool = false) {
        self.statistics = statistics; _expanded = State(initialValue: initiallyExpanded)
    }
    var body: some View {
        PulseCard {
            VStack(alignment: .leading, spacing: 14) {
                Button { expanded.toggle() } label: {
                    HStack {
                        Text(L10n.text("详细统计")).font(PulseTheme.font(size: 17, weight: .semibold))
                        Spacer()
                        Image(systemName: expanded ? "chevron.up" : "chevron.down").foregroundStyle(PulseTheme.secondary)
                    }.frame(minHeight: 28).contentShape(Rectangle())
                }.buttonStyle(.plain).accessibilityValue(L10n.text(expanded ? "已展开" : "已收起"))
                if expanded { ActivityStatisticsGrid(statistics: statistics) }
            }
        }
    }
}

struct ActivityChartsSection: View {
    let detail: GarminActivityDetail
    private var available: [ActivityMetricDefinition] { ActivityMetricCatalog.visibleCharts(detail) }
    var body: some View {
        LazyVStack(alignment: .leading, spacing: 12) {
            Text(L10n.text("运动图表")).font(PulseTheme.font(size: 17, weight: .semibold))
                .help(L10n.text("移动光标查看数值"))
            if available.isEmpty { Text(L10n.text("这条运动没有可用的图表数据")).foregroundStyle(PulseTheme.secondary) }
            if let heartRate = available.first(where: { $0.key == "directHeartRate" }) {
                PulseCard {
                    ActivityInteractiveChart(points: ActivityChartPoint.points(detail, metric: heartRate.key), metric: heartRate, height: 210)
                }
            }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 290), spacing: 12)], spacing: 12) {
                ForEach(available.filter { $0.key != "directHeartRate" }) { metric in
                    PulseCard {
                        ActivityInteractiveChart(points: ActivityChartPoint.points(detail, metric: metric.key), metric: metric, height: 160)
                    }
                }
            }
        }
    }
}

struct ActivityZonesSection: View {
    let detail: GarminActivityDetail
    var body: some View {
        PulseCard {
            VStack(alignment: .leading, spacing: 14) {
                Text(L10n.text("心率区间")).font(PulseTheme.font(size: 17, weight: .semibold))
                if let zones = detail.heartRateZones {
                    if zones.isEmpty { Text(L10n.text("这条运动没有心率区间数据")) }
                    let total = zones.reduce(0) { $0 + $1.seconds }
                    ForEach(zones) { zone in
                        VStack(alignment: .leading, spacing: 7) {
                            HStack {
                                Text("Z\(zone.number)").fontWeight(.semibold)
                                if let lower = zone.lowerBPM { Text(String(format: "≥ %.0f bpm", lower)).foregroundStyle(PulseTheme.secondary) }
                                Spacer()
                                Text(ActivityMetricCatalog.duration(zone.seconds)).monospacedDigit()
                                Text(String(format: "%.1f%%", total > 0 ? zone.seconds / total * 100 : 0)).frame(width: 60, alignment: .trailing)
                            }
                            ProgressView(value: zone.seconds, total: max(total, 1)).tint(zoneColor(zone.number))
                        }.font(PulseTheme.font(size: 12)).padding(.vertical, 2)
                    }
                } else { ActivitySectionUnavailable() }
            }
        }
    }
    private func zoneColor(_ number: Int) -> Color {
        switch number { case 1: return .blue; case 2: return .green; case 3: return .yellow; case 4: return .orange; default: return .red }
    }
}

struct ActivityLapsSection: View {
    let detail: GarminActivityDetail
    var body: some View {
        PulseCard {
            VStack(alignment: .leading, spacing: 14) {
                Text(L10n.text("运动分段")).font(PulseTheme.font(size: 17, weight: .semibold))
                if let laps = detail.laps {
                    if laps.isEmpty { Text(L10n.text("这条运动没有分段数据")) }
                    ForEach(laps) { lap in ActivityLapRow(lap: lap) }
                } else { ActivitySectionUnavailable() }
            }
        }
    }
}

private struct ActivityLapRow: View {
    let lap: GarminActivityLap
    @State private var expanded = false
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Button { expanded.toggle() } label: {
                HStack {
                    Image(systemName: expanded ? "chevron.down" : "chevron.right").frame(width: 14)
                    Text(L10n.format("分段 {0}", String(lap.index)))
                    Spacer()
                    if let seconds = lap.statistics["duration"] { Text(ActivityMetricCatalog.duration(seconds)).monospacedDigit() }
                    if let distance = lap.statistics["distance"], distance > 0 { Text(String(format: "%.2f km", distance / 1000)).monospacedDigit() }
                }.font(PulseTheme.font(size: 14, weight: .medium)).frame(minHeight: 28).contentShape(Rectangle())
            }.buttonStyle(.plain).accessibilityValue(L10n.text(expanded ? "已展开" : "已收起"))
            if expanded { ActivityStatisticsGrid(statistics: lap.statistics) }
        }.padding(12).background(PulseTheme.secondary.opacity(0.07), in: RoundedRectangle(cornerRadius: 10))
    }
}

private struct ActivitySectionUnavailable: View {
    var body: some View {
        Text(L10n.text("这部分数据暂时未能读取，可刷新详情重试。"))
            .font(PulseTheme.font(size: 12)).foregroundStyle(PulseTheme.secondary)
    }
}

private struct ActivityStatisticsGrid: View {
    let statistics: [String: Double]
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            ForEach(ActivityMetricCatalog.groups, id: \.self) { group in
                let fields = ActivityMetricCatalog.statistics.filter { $0.group == group && statistics[$0.key] != nil }
                if !fields.isEmpty {
                    VStack(alignment: .leading, spacing: 12) {
                        Text(L10n.text(group)).font(PulseTheme.font(size: 15, weight: .semibold))
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 140), spacing: 12)], alignment: .leading, spacing: 12) {
                            ForEach(fields) { field in
                                VStack(alignment: .leading, spacing: 5) {
                                    Text(L10n.text(field.label)).font(PulseTheme.font(size: 12)).foregroundStyle(PulseTheme.secondary)
                                    Text(field.formatted(statistics[field.key]!)).font(PulseTheme.font(size: 17, weight: .medium)).monospacedDigit()
                                }.frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }
                    }
                    Divider()
                }
            }
        }
    }
}

private struct ActivityInteractiveChart: View {
    let points: [ActivityChartPoint]
    let metric: ActivityMetricDefinition
    var height: CGFloat = 210
    @State private var selected: ActivityChartPoint?
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(L10n.text(metric.label)).font(PulseTheme.font(size: 14, weight: .semibold)).lineLimit(1)
                Spacer()
                if let selected {
                    Text(metric.formatted(selected.value)).font(PulseTheme.font(size: 13, weight: .medium)).monospacedDigit()
                } else { Text(metric.unit).font(PulseTheme.font(size: 11)).foregroundStyle(PulseTheme.secondary) }
            }.frame(height: 24)
            HStack {
                if let selected { Text(selected.time, style: .time) }
                else { Text(L10n.text("移动光标查看数值")) }
                Spacer()
            }.font(PulseTheme.font(size: 10)).foregroundStyle(PulseTheme.secondary).frame(height: 14)
            Chart {
                ForEach(points) { point in
                    LineMark(x: .value("Time", point.time), y: .value(metric.unit, point.value), series: .value("Segment", point.segment))
                        .foregroundStyle(PulseTheme.mint)
                }
                if let selected {
                    RuleMark(x: .value("Time", selected.time)).foregroundStyle(PulseTheme.secondary.opacity(0.5))
                    PointMark(x: .value("Time", selected.time), y: .value(metric.unit, selected.value)).foregroundStyle(PulseTheme.mint)
                }
            }
            .chartXAxis { AxisMarks(values: .automatic(desiredCount: 4)) }
            .frame(height: height)
            .chartOverlay { proxy in
                GeometryReader { geometry in
                    Rectangle().fill(.clear).contentShape(Rectangle()).onContinuousHover { phase in
                        switch phase {
                        case .active(let location):
                            let plot = geometry[proxy.plotAreaFrame]
                            guard plot.contains(location), let time: Date = proxy.value(atX: location.x - plot.minX) else { selected = nil; return }
                            selected = points.min { abs($0.time.timeIntervalSince(time)) < abs($1.time.timeIntervalSince(time)) }
                        case .ended: selected = nil
                        }
                    }
                }
            }
        }
    }
}

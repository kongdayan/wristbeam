import SwiftUI
import Charts

struct ActivityDetailContent: View {
    let summary: GarminActivity
    let detail: GarminActivityDetail?
    var body: some View {
        LazyVStack(alignment: .leading, spacing: 24) {
            PulseCard { ActivityStatisticsGrid(statistics: summary.statistics) }
            if let detail {
                ActivityChartsSection(detail: detail)
                ActivityZonesSection(detail: detail)
                ActivityLapsSection(detail: detail)
            }
        }
    }
}

struct ActivityChartsSection: View {
    let detail: GarminActivityDetail
    private var available: [ActivityMetricDefinition] {
        ActivityMetricCatalog.charts.filter { field in
            detail.series.contains { $0.key == field.key && $0.values.contains(where: { $0 != nil }) }
        }
    }
    var body: some View {
        LazyVStack(alignment: .leading, spacing: 18) {
            Text(L10n.text("运动图表")).font(PulseTheme.font(size: 20, weight: .semibold))
            if available.isEmpty { Text(L10n.text("这条运动没有可用的图表数据")).foregroundStyle(PulseTheme.secondary) }
            ForEach(available) { metric in
                PulseCard {
                    ActivityInteractiveChart(points: ActivityChartPoint.points(detail, metric: metric.key), metric: metric)
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
                Text(L10n.text("心率区间")).font(PulseTheme.font(size: 20, weight: .semibold))
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
                            ProgressView(value: zone.seconds, total: max(total, 1)).tint(PulseTheme.mint)
                        }.padding(.vertical, 6)
                    }
                } else { ActivitySectionUnavailable() }
            }
        }
    }
}

struct ActivityLapsSection: View {
    let detail: GarminActivityDetail
    var body: some View {
        PulseCard {
            VStack(alignment: .leading, spacing: 14) {
                Text(L10n.text("运动分段")).font(PulseTheme.font(size: 20, weight: .semibold))
                if let laps = detail.laps {
                    if laps.isEmpty { Text(L10n.text("这条运动没有分段数据")) }
                    ForEach(laps) { lap in
                        DisclosureGroup {
                            ActivityStatisticsGrid(statistics: lap.statistics).padding(.top, 12)
                        } label: {
                            HStack {
                                Text(L10n.format("分段 {0}", String(lap.index)))
                                Spacer()
                                if let seconds = lap.statistics["duration"] { Text(ActivityMetricCatalog.duration(seconds)).monospacedDigit() }
                                if let distance = lap.statistics["distance"] { Text(String(format: "%.2f km", distance / 1000)).monospacedDigit() }
                            }.font(PulseTheme.font(size: 14, weight: .medium))
                        }.padding(12).background(PulseTheme.secondary.opacity(0.07), in: RoundedRectangle(cornerRadius: 10))
                    }
                } else { ActivitySectionUnavailable() }
            }
        }
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
        VStack(alignment: .leading, spacing: 22) {
            ForEach(ActivityMetricCatalog.groups, id: \.self) { group in
                let fields = ActivityMetricCatalog.statistics.filter { $0.group == group && statistics[$0.key] != nil }
                if !fields.isEmpty {
                    VStack(alignment: .leading, spacing: 12) {
                        Text(L10n.text(group)).font(PulseTheme.font(size: 15, weight: .semibold))
                        LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible())], alignment: .leading, spacing: 16) {
                            ForEach(fields) { field in
                                VStack(alignment: .leading, spacing: 5) {
                                    Text(L10n.text(field.label)).font(PulseTheme.font(size: 12)).foregroundStyle(PulseTheme.secondary)
                                    Text(field.formatted(statistics[field.key]!)).font(PulseTheme.font(size: 19, weight: .medium)).monospacedDigit()
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
    @State private var selected: ActivityChartPoint?
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(L10n.text(metric.label)).font(PulseTheme.font(size: 17, weight: .semibold))
                Spacer()
                if let selected {
                    Text(selected.time, style: .time)
                    Text(metric.formatted(selected.value)).monospacedDigit()
                } else { Text(L10n.text("移动光标查看数值")).foregroundStyle(PulseTheme.secondary) }
            }.frame(height: 28)
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
            .chartYAxisLabel(metric.unit)
            .frame(height: 280)
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

import SwiftUI
import Charts

struct HRVTrendMiniChart: View {
    let series: MetricDaySeries?
    var body: some View {
        VStack(spacing: 3) {
            Canvas { context, size in
                guard let series, let first = series.points.first, let last = series.points.last else { return }
                let values = series.points.compactMap(\.value)
                let low = max(0, (values.min() ?? 0) - 5), high = (values.max() ?? 1) + 5
                let duration = max(86400, last.timestamp.timeIntervalSince(first.timestamp))
                var path = Path(), previous: Date?
                for point in series.points {
                    guard let value = point.value else { previous = nil; continue }
                    let xy = CGPoint(x: point.timestamp.timeIntervalSince(first.timestamp) / duration * size.width, y: size.height - (value - low) / max(1, high - low) * size.height)
                    if let previous, point.timestamp.timeIntervalSince(previous) < 129600 { path.addLine(to: xy) } else { path.move(to: xy) }
                    context.fill(Path(ellipseIn: CGRect(x: xy.x - 2, y: xy.y - 2, width: 4, height: 4)), with: .color(PulseTheme.mint))
                    previous = point.timestamp
                }
                context.stroke(path, with: .color(PulseTheme.mint), lineWidth: 1.5)
            }
            HStack {
                if let first = series?.points.first { Text(first.timestamp, format: .dateTime.month().day()) }
                Spacer()
                if let last = series?.points.last { Text(last.timestamp, format: .dateTime.month().day()) }
            }.font(PulseTheme.font(size: 9)).foregroundStyle(PulseTheme.secondary)
        }.accessibilityLabel(L10n.text("夜间 HRV 历史趋势"))
    }
}

struct HRVDetailView: View {
    @ObservedObject var model: AppModel
    let kind: MetricKind
    @State private var selectedDay: Date?
    @State private var range = 28
    @State private var cursor: Date?
    private var report: GarminHRVReport? { model.hrvReport }
    private var day: Date { selectedDay ?? report?.latest?.day ?? Calendar.current.startOfDay(for: Date()) }
    private var summary: GarminHRVSummary? { report?.summaries.first { Calendar.current.isDate($0.day, inSameDayAs: day) } }
    private var nights: [MetricSeriesPoint] { report?.nights[GarminHealthMetrics.calendarDate(day)] ?? [] }
    private var days: [GarminHRVSummary] {
        let cutoff = Calendar.current.date(byAdding: .day, value: -(range - 1), to: Calendar.current.startOfDay(for: Date()))!
        return (report?.summaries ?? []).filter { $0.day >= cutoff }
    }
    private var nearest: MetricSeriesPoint? {
        guard let cursor else { return nil }
        guard let point = nights.min(by: { abs($0.timestamp.timeIntervalSince(cursor)) < abs($1.timestamp.timeIntervalSince(cursor)) }), abs(point.timestamp.timeIntervalSince(cursor)) <= 300 else { return nil }
        return point
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                Button { model.detailMetric = nil } label: { Label(L10n.text("返回健康看板"), systemImage: "chevron.left") }.buttonStyle(.bordered).controlSize(.large)
                Spacer()
                Button(L10n.text("刷新记录")) { Task { await model.refreshHealthMetrics(force: true); await model.loadHRVNight(day) } }
                    .disabled(model.preview || model.isRefreshingHealth || model.hrvLoading).buttonStyle(.bordered)
            }
            Text(L10n.text("夜间 HRV 与恢复趋势")).font(PulseTheme.font(size: 25, weight: .semibold))
            Text(L10n.text("来自佳明云的睡眠期 HRV。与实时心搏间期（RR）分别展示，不计算或冒充实时 HRV。"))
                .font(PulseTheme.font(size: 12)).foregroundStyle(PulseTheme.secondary)
            HStack {
                DatePicker(L10n.text("夜间记录日期"), selection: Binding(get: { day }, set: { selectedDay = $0; cursor = nil }), in: ...Date(), displayedComponents: .date)
                    .datePickerStyle(.field).frame(maxWidth: 270)
                Button(L10n.text("最近可用记录")) { selectedDay = report?.latest?.day }.buttonStyle(.bordered)
                Spacer()
            }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 150))], spacing: 12) {
                valueCard("夜间 HRV", value: summary?.night, unit: "毫秒")
                valueCard("HRV 七天平均", value: summary?.weekly, unit: "毫秒")
                valueCard("HRV 最高五分钟", value: summary?.high, unit: "毫秒")
                PulseCard { VStack(alignment: .leading, spacing: 10) {
                    Text(L10n.text("HRV 状态")).font(PulseTheme.font(size: 12)).foregroundStyle(PulseTheme.secondary)
                    Text(summary?.status?.title ?? "—").font(PulseTheme.font(size: 19, weight: .semibold))
                    if let lower = summary?.baselineLow, let upper = summary?.baselineHigh {
                        Text(L10n.format("个人基线：{0}–{1} 毫秒", number(lower), number(upper))).font(PulseTheme.font(size: 10)).foregroundStyle(PulseTheme.secondary)
                    } else { Text(L10n.text("云端尚未提供个人基线")).font(PulseTheme.font(size: 10)).foregroundStyle(PulseTheme.secondary) }
                } }
            }
            if summary?.weekly == nil { Text(L10n.text("云端尚未提供七天平均；已有夜间记录仍可查看。")).font(PulseTheme.font(size: 12)).foregroundStyle(PulseTheme.secondary) }
            PulseCard {
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Text(L10n.text("夜间采样")).font(PulseTheme.font(size: 15, weight: .semibold))
                        Spacer()
                        if let point = nearest, let value = point.value {
                            Text(point.timestamp, format: .dateTime.hour().minute())
                            Text("\(number(value)) \(L10n.text("毫秒"))").monospacedDigit()
                        }
                    }
                    if !nights.contains(where: { $0.value != nil }) {
                        Text(L10n.text(model.hrvLoading ? "正在读取夜间 HRV…" : "该夜间尚无 HRV 记录")).frame(maxWidth: .infinity, minHeight: 140).foregroundStyle(PulseTheme.secondary)
                    } else {
                        Chart {
                            ForEach(Array(nightSegments.enumerated()), id: \.offset) { index, segment in
                                ForEach(segment) { point in
                                    if let value = point.value { LineMark(x: .value("Time", point.timestamp), y: .value("HRV", value), series: .value("Segment", index)).foregroundStyle(PulseTheme.mint) }
                                }
                            }
                            if let point = nearest, let value = point.value {
                                RuleMark(x: .value("Time", point.timestamp)).foregroundStyle(Color.secondary.opacity(0.4))
                                PointMark(x: .value("Time", point.timestamp), y: .value("HRV", value)).foregroundStyle(PulseTheme.mint)
                            }
                        }.chartYScale(domain: .automatic(includesZero: false)).frame(height: 210)
                            .chartOverlay { proxy in
                                GeometryReader { geometry in
                                    Rectangle().fill(.clear).contentShape(Rectangle()).onContinuousHover { phase in
                                        switch phase {
                                        case .active(let location):
                                            let frame = geometry[proxy.plotAreaFrame]
                                            cursor = frame.contains(location) ? proxy.value(atX: location.x - frame.minX, as: Date.self) : nil
                                        case .ended: cursor = nil
                                        }
                                    }
                                }
                            }
                    }
                    Text(L10n.text("按真实夜间时间绘制，跨午夜记录保留；移动鼠标查看毫秒读数，缺测留空。"))
                        .font(PulseTheme.font(size: 11)).foregroundStyle(PulseTheme.secondary)
                    if !model.hrvMessage(for: day).isEmpty { Text(L10n.text(model.hrvMessage(for: day))).foregroundStyle(.orange) }
                }
            }
            PulseCard {
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Text(L10n.text("夜间均值与七天平均")).font(PulseTheme.font(size: 15, weight: .semibold))
                        Spacer()
                        Picker(L10n.text("时间范围"), selection: $range) { Text(L10n.text("7 天")).tag(7); Text(L10n.text("28 天")).tag(28) }.pickerStyle(.segmented).frame(width: 180)
                    }
                    Chart(days) { item in
                        if let low = item.baselineLow, let high = item.baselineHigh {
                            RectangleMark(xStart: .value("Day", item.day.addingTimeInterval(-21600)), xEnd: .value("Day", item.day.addingTimeInterval(21600)), yStart: .value("Low", low), yEnd: .value("High", high)).foregroundStyle(PulseTheme.mint.opacity(0.15))
                        }
                        if let value = item.night { BarMark(x: .value("Day", item.day, unit: .day), y: .value("HRV", value)).foregroundStyle(PulseTheme.mint.opacity(0.7)) }
                        if let value = item.weekly { PointMark(x: .value("Day", item.day), y: .value("HRV", value)).foregroundStyle(Color.orange).symbolSize(35) }
                    }.frame(height: 180)
                    Text(L10n.text("绿色：夜间均值；橙色：佳明七天平均；淡色范围：个人基线。点击下方日期查看当晚。"))
                        .font(PulseTheme.font(size: 11)).foregroundStyle(PulseTheme.secondary)
                    ForEach(days.reversed()) { item in
                        Button { selectedDay = item.day; cursor = nil } label: {
                            HStack {
                                Text(item.day, format: .dateTime.month().day())
                                Spacer()
                                Text(number(item.night) + " / " + number(item.weekly) + " " + L10n.text("毫秒"))
                                Text(item.status?.title ?? "—").frame(minWidth: 80, alignment: .trailing)
                            }.padding(.vertical, 6).contentShape(Rectangle())
                        }.buttonStyle(.plain)
                    }
                }
            }
        }.task(id: day) { if report?.nights[GarminHealthMetrics.calendarDate(day)] == nil { await model.loadHRVNight(day) } }
    }
    private var nightSegments: [[MetricSeriesPoint]] {
        var result: [[MetricSeriesPoint]] = [], current: [MetricSeriesPoint] = []
        for point in nights {
            if point.value == nil || current.last.map({ point.timestamp.timeIntervalSince($0.timestamp) > 900 }) == true {
                if !current.isEmpty { result.append(current); current = [] }
            }
            if point.value != nil { current.append(point) }
        }
        if !current.isEmpty { result.append(current) }; return result
    }
    private func number(_ value: Double?) -> String { value.map { $0.formatted(.number.precision(.fractionLength(0))) } ?? "—" }
    private func valueCard(_ title: String, value: Double?, unit: String) -> some View {
        PulseCard { VStack(alignment: .leading, spacing: 10) {
            Text(L10n.text(title)).font(PulseTheme.font(size: 12)).foregroundStyle(PulseTheme.secondary)
            Text(number(value)).font(PulseTheme.font(size: 28, weight: .medium, design: .rounded)).monospacedDigit()
            Text(L10n.text(unit)).font(PulseTheme.font(size: 10)).foregroundStyle(PulseTheme.secondary)
        } }
    }
}

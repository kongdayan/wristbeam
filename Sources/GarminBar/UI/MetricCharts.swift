import SwiftUI
import Charts

// Process-local performance counters, without pointer positions or health values.
// They are available only through the existing local --status diagnostics.
enum ChartRenderDiagnostics {
    static var plotBuilds: [String: Int] = [:]
    static var cursorEvents = 0
    static func built(_ kind: MetricKind) { plotBuilds[kind.rawValue, default: 0] += 1 }
}

private func chartRange(_ kind: MetricKind, series: MetricDaySeries?) -> ClosedRange<Double> {
    if ["solarIntensity", "bodyBattery", "stress", "spo2", "watchBattery", "trainingReadiness"].contains(kind.rawValue) { return 0...100 }
    let low = series?.minimum ?? 0, high = series?.maximum ?? 1
    if kind.seriesStyle == .bars { return 0...max(1, high * 1.1) }
    let padding = max(2, (high - low) * 0.12)
    return max(0, low - padding)...max(low + 1, high + padding)
}

private func stressColor(_ value: Double?) -> Color {
    guard let value else { return .gray.opacity(0.6) }
    switch value {
    case ...25: return Color(red: 0.38, green: 0.67, blue: 1)
    case ...50: return Color(red: 1, green: 0.82, blue: 0.35)
    case ...75: return Color(red: 1, green: 0.58, blue: 0.25)
    default: return Color(red: 1, green: 0.35, blue: 0.36)
    }
}

/// Small cards use the same timestamp domain as the detail chart. Canvas avoids
/// creating thousands of chart marks in each always-visible floating card.
struct MetricMiniChart: View, Equatable {
    let series: MetricDaySeries?
    let kind: MetricKind
    var axes = true
    var textScale = PulseTheme.textScale
    var language = L10n.language
    var body: some View {
        VStack(spacing: 3) {
            Canvas { context, size in
                let range = chartRange(kind, series: series)
                let start = series?.day ?? Calendar.current.startOfDay(for: Date())
                let end = Calendar.current.date(byAdding: .day, value: 1, to: start)!
                func x(_ date: Date) -> CGFloat { max(0, min(size.width, date.timeIntervalSince(start) / end.timeIntervalSince(start) * size.width)) }
                func y(_ value: Double) -> CGFloat { size.height - (value - range.lowerBound) / (range.upperBound - range.lowerBound) * (size.height - 2) }
                var grid = Path()
                for fraction in [0.0, 0.5, 1.0] { grid.move(to: CGPoint(x: fraction * size.width, y: 0)); grid.addLine(to: CGPoint(x: fraction * size.width, y: size.height)) }
                grid.move(to: CGPoint(x: 0, y: size.height)); grid.addLine(to: CGPoint(x: size.width, y: size.height))
                context.stroke(grid, with: .color(Color.primary.opacity(0.07)), style: StrokeStyle(lineWidth: 0.6))
                guard let original = series else { return }
                let series = original.sampled(width: Double(size.width), domain: start...end)
                if kind.seriesStyle == .bars {
                    for point in series.points {
                        let value = point.value, baseline = y(0)
                        let left = x(point.timestamp)
                        let width = point.end.map { max(0.7, x($0) - left - 0.5) } ?? 1.2
                        let top = value.map { y($0) } ?? baseline - 2
                        let rect = CGRect(x: left, y: top, width: width, height: max(0.8, baseline - top))
                        context.fill(Path(rect), with: .color(kind == .stress ? stressColor(value) : PulseTheme.color(kind).opacity(0.8)))
                    }
                } else {
                    for segment in series.segments {
                        var line = Path()
                        for (index, point) in segment.enumerated() {
                            let position = CGPoint(x: x(point.timestamp), y: y(point.value!))
                            if index == 0 { line.move(to: position) } else { line.addLine(to: position) }
                        }
                        if kind.seriesStyle == .area, let first = segment.first, let last = segment.last, segment.count > 1 {
                            var area = line
                            area.addLine(to: CGPoint(x: x(last.timestamp), y: size.height))
                            area.addLine(to: CGPoint(x: x(first.timestamp), y: size.height)); area.closeSubpath()
                            context.fill(area, with: .color(PulseTheme.color(kind).opacity(0.14)))
                        }
                        context.stroke(line, with: .color(PulseTheme.color(kind)), style: StrokeStyle(lineWidth: 1.3, lineCap: .round, lineJoin: .round))
                        if segment.count == 1, let point = segment.first {
                            context.fill(Path(ellipseIn: CGRect(x: x(point.timestamp) - 1.5, y: y(point.value!) - 1.5, width: 3, height: 3)), with: .color(PulseTheme.color(kind)))
                        }
                    }
                }
            }
            .overlay {
                if series?.values.isEmpty ?? true { Text(L10n.text("暂无时间序列")).font(PulseTheme.font(size: 8)).foregroundStyle(PulseTheme.secondary) }
            }
            .accessibilityLabel(L10n.text("\(kind.title)全天趋势，\(series?.values.count ?? 0)条记录，0点到24点"))
            if axes {
                HStack { Text(L10n.text("0:00")); Spacer(); Text(L10n.text("12:00")); Spacer(); Text(L10n.text("24:00")) }
                    .font(PulseTheme.font(size: 7)).foregroundStyle(PulseTheme.secondary)
            }
        }
    }
}

private enum ChartWindow: String, CaseIterable { case day = "全天", sixHours = "6 小时", hour = "1 小时" }

struct MetricDetailView: View {
    @ObservedObject var model: AppModel
    let kind: MetricKind
    @State private var selectedTime: Date? = nil
    @State private var window = ChartWindow.day
    @State private var anchor: Date? = nil
    @State private var overlayStress = true
    @State private var rowSelection: Date? = nil
    private var canonical: MetricKind { kind.timelineKind ?? kind }
    private var series: MetricDaySeries? { model.series(for: kind, day: model.detailDay) }
    private var stress: MetricDaySeries? { canonical == .bodyBattery && overlayStress ? model.series(for: .stress, day: model.detailDay) : nil }
    private var selected: MetricSeriesPoint? {
        guard let selectedTime else { return nil }
        return series?.reading(at: selectedTime)
    }
    private var domain: ClosedRange<Date> {
        let start = Calendar.current.startOfDay(for: model.detailDay)
        let end = Calendar.current.date(byAdding: .day, value: 1, to: start)!
        guard window != .day else { return start...end }
        let seconds: TimeInterval = window == .hour ? 3600 : 21600
        let focus = anchor ?? series?.latest?.timestamp ?? start.addingTimeInterval(43200)
        let lower = min(max(start, focus.addingTimeInterval(-seconds / 2)), end.addingTimeInterval(-seconds))
        return lower...lower.addingTimeInterval(seconds)
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack {
                PulseBackButton(title: "返回健康看板") { model.goBack() }
                Spacer()
                Button(L10n.text("刷新记录")) { Task { await model.refreshSeries(day: model.detailDay, force: true) } }
                    .buttonStyle(.bordered).disabled(!model.cloud.isAuthenticated || model.loadingSeriesDays.contains(GarminHealthMetrics.calendarDate(model.detailDay)))
            }.font(PulseTheme.font(size: 11))
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 7) {
                    HStack { MetricIcon(kind: kind, size: 28); Text(L10n.text(kind.title)) }.font(PulseTheme.font(size: 25, weight: .semibold)).foregroundStyle(PulseTheme.color(canonical))
                    Text(L10n.text(kind.timelineKind == nil ? "当日汇总" : "\(canonical.title) · 按实际时间查看全天记录")).font(PulseTheme.font(size: 11)).foregroundStyle(PulseTheme.secondary)
                }
                Spacer()
                if Calendar.current.isDateInToday(model.detailDay) {
                    VStack(alignment: .trailing, spacing: 3) {
                        Text(L10n.text(model.display(kind))).font(PulseTheme.font(size: 28, weight: .medium, design: .rounded)).monospacedDigit()
                        Text(L10n.text("\(kind.unit) · \(kind.group == .daily ? "今日汇总" : "最近读数")")).font(PulseTheme.font(size: 9)).foregroundStyle(PulseTheme.secondary)
                    }
                }
            }
            HStack(spacing: 10) {
                Button { changeDay(-1) } label: { Image(systemName: "chevron.left").font(PulseTheme.font(size: 16, weight: .semibold)).frame(width: 28, height: 28) }.buttonStyle(.bordered).help(L10n.text("前一天"))
                DatePicker("日期", selection: $model.detailDay, in: ...Date(), displayedComponents: .date).labelsHidden().datePickerStyle(.field)
                Button { changeDay(1) } label: { Image(systemName: "chevron.right").font(PulseTheme.font(size: 16, weight: .semibold)).frame(width: 28, height: 28) }.buttonStyle(.bordered).disabled(Calendar.current.isDateInToday(model.detailDay)).help(L10n.text("后一天"))
                Button(L10n.text("今天")) { model.detailDay = Date() }.buttonStyle(.bordered).foregroundStyle(PulseTheme.mint)
                Spacer()
                if kind.timelineKind != nil {
                    Picker(L10n.text("时间范围"), selection: $window) { ForEach(ChartWindow.allCases, id: \.self) { Text(L10n.text($0.rawValue)).tag($0) } }.pickerStyle(.segmented).frame(width: 240)
                }
            }.controlSize(.large)
            if kind.timelineKind != nil {
                PulseCard {
                    VStack(alignment: .leading, spacing: 14) {
                        chartReading
                        DailyMetricChart(series: series, stress: stress, kind: canonical, domain: domain, selectedTime: $selectedTime, threshold: model.sunlightThreshold)
                            .frame(height: 235)
                        if canonical == .bodyBattery {
                            Toggle(L10n.text("叠加同期压力"), isOn: $overlayStress).toggleStyle(.switch).controlSize(.small)
                        }
                        if canonical == .stress || canonical == .bodyBattery && overlayStress { stressLegend }
                        Text(L10n.text(series?.source ?? "等待真实记录")).font(PulseTheme.font(size: 10)).foregroundStyle(PulseTheme.secondary)
                        if let note = model.seriesNotes[GarminHealthMetrics.calendarDate(model.detailDay)]?[canonical] {
                            Text(L10n.text(note)).font(PulseTheme.font(size: 10)).foregroundStyle(.orange)
                        }
                        if model.loadingSeriesDays.contains(GarminHealthMetrics.calendarDate(model.detailDay)) { ProgressView(L10n.text("正在读取当天记录…")).controlSize(.small) }
                        Text(L10n.text("移动鼠标或点击图表查看读数；可切换 6 小时 / 1 小时，查看选中时刻附近。空白表示缺测、未同步或尚未发生的时间。")).font(PulseTheme.font(size: 10)).foregroundStyle(PulseTheme.secondary)
                    }
                }
                summary
                Text(L10n.text(canonical.seriesExplanation)).font(PulseTheme.font(size: 11)).foregroundStyle(PulseTheme.secondary)
                if let series, !series.points.isEmpty {
                    PulseDisclosure(L10n.text("查看原始时间记录（\(series.points.count) 条）")) {
                        Table(series.points, selection: $rowSelection) {
                            TableColumn(L10n.text("时间")) { point in Text(L10n.text(intervalLabel(point))).monospacedDigit() }
                            TableColumn(L10n.text("\(canonical.title)（\(canonical.seriesUnit)）")) { point in Text(L10n.text(point.value.map { formatted($0) } ?? "不可测 / 缺测")).monospacedDigit() }
                            TableColumn(L10n.text("记录类型")) { point in Text(L10n.text(point.origin == .watch ? "Mac 接收" : point.label ?? (point.charging == true ? "太阳能充电中" : model.cloud.region.title))) }
                        }.frame(height: 230)
                        Text(L10n.text("点击一条记录，将在图表中定位到对应时间。")).font(PulseTheme.font(size: 10)).foregroundStyle(PulseTheme.secondary)
                    }.font(PulseTheme.font(size: 12))
                }
            } else {
                PulseCard {
                    VStack(alignment: .leading, spacing: 12) {
                        Text(L10n.text("这是一项统计值，没有对应的小时级时间曲线。")).font(PulseTheme.font(size: 13))
                        Text(L10n.text(Calendar.current.isDateInToday(model.detailDay) ? model.detail(kind) : "当前版本仅显示此项的今日汇总；全天趋势支持切换历史日期。")).font(PulseTheme.font(size: 11)).foregroundStyle(PulseTheme.secondary)
                        if let trend = kind.relatedTrend, model.availableMetricKinds.contains(trend) || model.series(for: trend, day: model.detailDay) != nil {
                            Button(L10n.format("查看{0}全天趋势", trend.title)) { model.detailMetric = trend }.buttonStyle(.bordered)
                        }
                    }
                }
            }
        }
        .onChange(of: model.detailDay) { date in selectedTime = nil; anchor = nil; rowSelection = nil; Task { await model.refreshSeries(day: date) } }
        .onChange(of: window) { _ in anchor = selected?.timestamp ?? selectedTime ?? series?.latest?.timestamp }
        .onChange(of: rowSelection) { date in if let date { selectedTime = date; anchor = date } }
        .onChange(of: kind) { _ in selectedTime = nil; anchor = nil; rowSelection = nil }
    }
    private var chartReading: some View {
        HStack(alignment: .firstTextBaseline) {
            if let time = selectedTime {
                Text(L10n.text((selected?.timestamp ?? time).formatted(Date.FormatStyle(date: .omitted, time: .shortened).locale(L10n.locale)))).font(PulseTheme.font(size: 13, weight: .medium)).monospacedDigit()
                Text(L10n.text(selected?.value.map { "\(formatted($0)) \(canonical.seriesUnit)" } ?? "该时段无可用读数")).font(PulseTheme.font(size: 17, weight: .medium)).foregroundStyle(PulseTheme.color(canonical))
                Spacer()
                Text(L10n.text(selected?.origin == .watch ? "Mac 接收" : selected?.label ?? (selected?.charging == true ? "太阳能充电中" : model.cloud.region.title))).font(PulseTheme.font(size: 9)).foregroundStyle(PulseTheme.secondary)
            } else {
                Text(L10n.text("\(model.detailDay.formatted(.dateTime.month().day().locale(L10n.locale))) · 0:00–24:00")).font(PulseTheme.font(size: 12, weight: .medium))
                Spacer()
                Text(L10n.text("\(series?.values.count ?? 0) 条有效记录")).font(PulseTheme.font(size: 10)).foregroundStyle(PulseTheme.secondary)
            }
        }.frame(height: 24)
    }
    private var stressLegend: some View {
        HStack(spacing: 12) {
            ForEach(Array(zip(["休息", "低压力", "中压力", "高压力", "不可测"], [10.0, 35, 60, 85, -1])), id: \.0) { title, value in
                HStack(spacing: 4) { Circle().fill(stressColor(value < 0 ? nil : value)).frame(width: 5, height: 5); Text(L10n.text(title)) }
            }
        }.font(PulseTheme.font(size: 9)).foregroundStyle(PulseTheme.secondary)
    }
    private var summary: some View {
        HStack(spacing: 10) {
            stat("最高", series?.maximum.map(formatted) ?? "—", canonical.seriesUnit)
            stat("最低", series?.minimum.map(formatted) ?? "—", canonical.seriesUnit)
            if canonical == .solarIntensity {
                stat("强度 ≥ \(Int(model.sunlightThreshold))%", series.map { String($0.values.filter { ($0.value ?? 0) >= model.sunlightThreshold && ($0.value ?? 0) > 0 }.count) } ?? "—", "分 · 日照估算")
                stat("太阳能充电", series.map { String($0.values.filter { $0.charging == true && ($0.value ?? 0) > 0 }.count) } ?? "—", "分 · 记录估算")
            } else if canonical.seriesStyle == .bars && canonical != .stress {
                stat("分时记录合计", series?.total.map(formatted) ?? "—", canonical.seriesUnit)
                stat("有效时间段", String(series?.values.count ?? 0), "段")
            } else {
                stat("采样均值", series?.mean.map { $0.formatted(.number.precision(.fractionLength(1))) } ?? "—", canonical.seriesUnit)
                stat("最近记录", series?.latest?.timestamp.formatted(Date.FormatStyle(date: .omitted, time: .shortened).locale(L10n.locale)) ?? "—", "实际采样时间")
            }
        }
    }
    private func stat(_ title: String, _ value: String, _ unit: String) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(L10n.text(title)).font(PulseTheme.font(size: 9)).foregroundStyle(PulseTheme.secondary)
            Text(L10n.text(value)).font(PulseTheme.font(size: 21, weight: .medium, design: .rounded)).monospacedDigit().lineLimit(1).minimumScaleFactor(0.7)
            Text(L10n.text(unit)).font(PulseTheme.font(size: 8)).foregroundStyle(PulseTheme.secondary)
        }.padding(14).frame(maxWidth: .infinity, alignment: .leading).background(PulseTheme.surface).clipShape(RoundedRectangle(cornerRadius: 12))
    }
    private func changeDay(_ amount: Int) { if let date = Calendar.current.date(byAdding: .day, value: amount, to: model.detailDay) { model.detailDay = min(date, Date()) } }
    private func formatted(_ value: Double) -> String { value.formatted(.number.precision(.fractionLength(canonical.definition.decimals))) }
    private func intervalLabel(_ point: MetricSeriesPoint) -> String {
        let start = point.timestamp.formatted(Date.FormatStyle(date: .omitted, time: .shortened).locale(L10n.locale))
        return point.end.map { "\(start)–\($0.formatted(Date.FormatStyle(date: .omitted, time: .shortened).locale(L10n.locale)))" } ?? start
    }
}

private struct DailyMetricChart: View {
    let series: MetricDaySeries?
    let stress: MetricDaySeries?
    let kind: MetricKind
    let domain: ClosedRange<Date>
    @Binding var selectedTime: Date?
    let threshold: Double
    var body: some View {
        GeometryReader { geometry in
            MetricChartPlot(series: series, stress: stress, kind: kind, domain: domain,
                selectedTime: $selectedTime, threshold: threshold, renderWidth: max(1, geometry.size.width - 50)).equatable()
        }
    }
}

// Cursor movement does not invalidate the static chart. Native chart marks are
// rebuilt only when data, date range, stress overlay or threshold actually change.
private struct MetricChartPlot: View, Equatable {
    let series: MetricDaySeries?
    let stress: MetricDaySeries?
    let kind: MetricKind
    let domain: ClosedRange<Date>
    @Binding var selectedTime: Date?
    let threshold: Double
    let renderWidth: Double
    var textScale = PulseTheme.textScale
    var language = L10n.language
    static func == (left: Self, right: Self) -> Bool {
        left.renderWidth == right.renderWidth && left.series == right.series && left.stress == right.stress && left.kind == right.kind && left.domain == right.domain && left.threshold == right.threshold && left.textScale == right.textScale && left.language == right.language
    }
    var body: some View {
        let plotted = series?.sampled(width: renderWidth, domain: domain)
        let stressPlot = stress?.sampled(width: renderWidth, domain: domain)
        Chart {
            if let stress = stressPlot {
                ForEach(stress.points) { point in
                    if let value = point.value { BarMark(x: .value("时间", point.timestamp), y: .value("压力", value), width: .fixed(1.5)).foregroundStyle(stressColor(value).opacity(0.4)) }
                }
            }
            marks(plotted)
            if kind == .solarIntensity {
                RuleMark(y: .value("日照估算阈值", threshold)).foregroundStyle(PulseTheme.color(kind).opacity(0.35)).lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 4]))
            }
        }
        .chartXScale(domain: domain).chartYScale(domain: chartRange(kind, series: series))
        .chartLegend(.hidden)
        .chartXAxis {
            AxisMarks(preset: .aligned, values: axisDates) { value in
                AxisGridLine().foregroundStyle(Color.primary.opacity(0.07))
                AxisValueLabel(collisionResolution: .disabled) { if let date = value.as(Date.self) { Text(L10n.text(timeLabel(date))).font(PulseTheme.font(size: 9)).foregroundStyle(PulseTheme.secondary) } }
            }
        }
        .chartYAxis { AxisMarks(position: .leading) { _ in AxisGridLine().foregroundStyle(Color.primary.opacity(0.07)); AxisValueLabel().foregroundStyle(PulseTheme.secondary) } }
        .chartPlotStyle { plot in plot.clipped() }
        .chartOverlay { proxy in
            GeometryReader { geometry in
                MetricChartCursor(series: series, kind: kind, domain: domain, selectedTime: $selectedTime, proxy: proxy, plotFrame: geometry[proxy.plotAreaFrame])
            }
        }
        .overlay {
            if series?.values.isEmpty ?? true {
                VStack(spacing: 7) { Image(systemName: "chart.xyaxis.line"); Text(L10n.text("这一天暂无可用时间序列")); Text(L10n.text("请先同步手表，或选择有记录的日期。")) }
                    .font(PulseTheme.font(size: 11)).foregroundStyle(PulseTheme.secondary)
            }
        }
        .accessibilityLabel(L10n.text("\(kind.title)详细时间图，\(series?.values.count ?? 0)条有效记录"))
    }
    @ChartContentBuilder private func marks(_ series: MetricDaySeries?) -> some ChartContent {
        let _ = ChartRenderDiagnostics.built(kind)
        // Compute once per dataset, not once for every mark in every segment.
        let segments = series?.segments ?? []
        if kind.seriesStyle == .bars {
            ForEach(series?.points ?? []) { point in
                if let value = point.value {
                    if let end = point.end {
                        RectangleMark(xStart: .value("开始", point.timestamp), xEnd: .value("结束", end), yStart: .value("零", 0), yEnd: .value("新增", value)).foregroundStyle(PulseTheme.color(kind).opacity(0.8))
                    } else {
                        BarMark(x: .value("时间", point.timestamp), y: .value("读数", value), width: .fixed(2)).foregroundStyle(kind == .stress ? stressColor(value) : PulseTheme.color(kind))
                    }
                } else if kind == .stress {
                    BarMark(x: .value("时间", point.timestamp), y: .value("不可测", 1.5), width: .fixed(2)).foregroundStyle(stressColor(nil))
                }
            }
        } else {
            ForEach(segments.indices, id: \.self) { index in
                ForEach(segments[index]) { point in
                    if let value = point.value {
                        if kind.seriesStyle == .area {
                            AreaMark(x: .value("时间", point.timestamp), yStart: .value("零", 0), yEnd: .value("读数", value), series: .value("连续段", index)).foregroundStyle(PulseTheme.color(kind).opacity(0.12))
                        }
                        LineMark(x: .value("时间", point.timestamp), y: .value("读数", value), series: .value("连续段", index)).foregroundStyle(PulseTheme.color(kind)).lineStyle(StrokeStyle(lineWidth: 1.6)).interpolationMethod(.linear)
                        if segments[index].count == 1 || kind.rawValue == "spo2" {
                            PointMark(x: .value("时间", point.timestamp), y: .value("读数", value)).foregroundStyle(PulseTheme.color(kind)).symbolSize(12)
                        }
                    }
                }
            }
        }
    }
    private var axisDates: [Date] {
        let count = domain.upperBound.timeIntervalSince(domain.lowerBound) > 21600 ? 4 : 6
        let step = domain.upperBound.timeIntervalSince(domain.lowerBound) / Double(count)
        return (0...count).map { domain.lowerBound.addingTimeInterval(Double($0) * step) }
    }
    private func timeLabel(_ date: Date) -> String {
        if let day = series?.day, Calendar.current.date(byAdding: .day, value: 1, to: day) == date { return "24:00" }
        let components = Calendar.current.dateComponents([.hour, .minute], from: date)
        return String(format: "%02d:%02d", components.hour ?? 0, components.minute ?? 0)
    }
}

private struct MetricChartCursor: View {
    let series: MetricDaySeries?
    let kind: MetricKind
    let domain: ClosedRange<Date>
    @Binding var selectedTime: Date?
    let proxy: ChartProxy
    let plotFrame: CGRect
    var body: some View {
        ZStack {
            Canvas { context, _ in
                if let time = selectedTime, let position = proxy.position(forX: time) {
                    let x = plotFrame.minX + position
                    var path = Path(); path.move(to: CGPoint(x: x, y: plotFrame.minY)); path.addLine(to: CGPoint(x: x, y: plotFrame.maxY))
                    context.stroke(path, with: .color(Color.primary.opacity(0.6)), style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
                    if let point = series?.reading(at: time), let value = point.value,
                       let pointX = proxy.position(forX: point.end == nil ? point.timestamp : time), let pointY = proxy.position(forY: value) {
                        let circle = CGRect(x: plotFrame.minX + pointX - 3, y: plotFrame.minY + pointY - 3, width: 6, height: 6)
                        context.fill(Path(ellipseIn: circle), with: .color(PulseTheme.color(kind)))
                    }
                }
            }.allowsHitTesting(false)
            Rectangle().fill(.clear).contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 0).onChanged { read($0.location) })
                .onContinuousHover { phase in if case .active(let location) = phase { read(location) } }
        }
    }
    private func read(_ location: CGPoint) {
        guard plotFrame.contains(location), let date: Date = proxy.value(atX: location.x - plotFrame.minX) else { return }
        ChartRenderDiagnostics.cursorEvents += 1
        selectedTime = min(domain.upperBound, max(domain.lowerBound, date))
    }
}

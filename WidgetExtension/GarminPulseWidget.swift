import SwiftUI
import WidgetKit

struct PulseWidgetEntry: TimelineEntry {
    let date: Date
    let snapshot: PulseWidgetSnapshot
}

struct PulseWidgetProvider: TimelineProvider {
    func placeholder(in context: Context) -> PulseWidgetEntry { PulseWidgetEntry(date: Date(), snapshot: .empty) }
    func getSnapshot(in context: Context, completion: @escaping (PulseWidgetEntry) -> Void) { completion(read()) }
    func getTimeline(in context: Context, completion: @escaping (Timeline<PulseWidgetEntry>) -> Void) {
        completion(Timeline(entries: [read()], policy: .after(Date().addingTimeInterval(15 * 60))))
    }
    private func read() -> PulseWidgetEntry {
        guard let group = Bundle.main.object(forInfoDictionaryKey: PulseWidgetSnapshot.groupInfoKey) as? String,
              !group.isEmpty, !group.contains("$("),
              let root = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: group),
              let bytes = try? Data(contentsOf: root.appendingPathComponent(PulseWidgetSnapshot.fileName)),
              let snapshot = try? PulseWidgetSnapshot.decode(bytes) else { return PulseWidgetEntry(date: Date(), snapshot: .empty) }
        return PulseWidgetEntry(date: Date(), snapshot: snapshot)
    }
}

struct PulseSystemWidgetView: View {
    let entry: PulseWidgetEntry
    @Environment(\.widgetFamily) private var family
    private var limit: Int { family == .systemSmall ? 2 : family == .systemMedium ? 4 : 8 }
    private var columns: Int { family == .systemSmall ? 1 : 2 }
    private var readings: [PulseWidgetReading] { Array(entry.snapshot.readings.prefix(limit)) }
    private var scheme: ColorScheme? { entry.snapshot.appearance == "light" ? .light : entry.snapshot.appearance == "dark" ? .dark : nil }
    var body: some View {
        VStack(alignment: .leading, spacing: family == .systemSmall ? 8 : 12) {
            HStack(spacing: 6) {
                Image(systemName: "waveform.path.ecg").foregroundStyle(.green)
                Text("Garmin Pulse").font(.system(size: 12, weight: .semibold))
                Spacer(minLength: 0)
                if family != .systemSmall { Text(entry.snapshot.generatedAt, style: .time).font(.system(size: 10)).foregroundStyle(.secondary) }
            }
            if readings.isEmpty {
                Text("打开 Garmin Pulse，选择指标并连接手表。").font(.system(size: 12)).foregroundStyle(.secondary)
                Spacer()
            } else {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 14), count: columns), spacing: 10) {
                    ForEach(readings) { reading in
                        Link(destination: PulseWidgetLink.url(metricID: reading.id, day: entry.snapshot.day)) {
                            metric(reading)
                        }.buttonStyle(.plain)
                    }
                }
            }
            if family == .systemLarge { Text("\(entry.snapshot.regionTitle) · 点按指标查看详细曲线").font(.system(size: 10)).foregroundStyle(.secondary) }
        }
        .containerBackground(.background, for: .widget)
        .preferredColorScheme(scheme)
        .widgetURL(readings.first.map { PulseWidgetLink.url(metricID: $0.id, day: entry.snapshot.day) } ?? URL(string: "garminpulse://metric/heartRate"))
    }
    private func metric(_ reading: PulseWidgetReading) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 5) {
                Image(systemName: reading.symbol).foregroundStyle(color(reading))
                Text(reading.title).lineLimit(1)
            }.font(.system(size: 11)).foregroundStyle(.secondary)
            HStack(alignment: .firstTextBaseline, spacing: 3) {
                Text(reading.stale ? "—" : reading.value).font(.system(size: family == .systemLarge ? 23 : 21, weight: .medium, design: .rounded)).monospacedDigit().lineLimit(1).minimumScaleFactor(0.6)
                Text(reading.unit).font(.system(size: 9)).foregroundStyle(.secondary)
            }
            if family == .systemLarge { curve(reading).frame(height: 20) }
            HStack(spacing: 3) {
                if let timestamp = reading.updatedAt {
                    Text(reading.stale ? "上次" : "更新"); Text(timestamp, style: .time)
                } else { Text("等待同步") }
            }.font(.system(size: 9)).foregroundStyle(.secondary).lineLimit(1)
        }.frame(maxWidth: .infinity, alignment: .leading).privacySensitive()
    }
    private func color(_ reading: PulseWidgetReading) -> Color {
        switch reading.category { case "heart": return .red; case "solar": return .orange; case "body": return .blue; case "stress": return .orange; default: return .green }
    }
    private func curve(_ reading: PulseWidgetReading) -> some View {
        Canvas { context, size in
            let start = entry.snapshot.day
            let duration = Calendar.current.date(byAdding: .day, value: 1, to: start)!.timeIntervalSince(start)
            func x(_ seconds: Double) -> CGFloat { max(0, min(size.width, seconds / duration * size.width)) }
            func y(_ value: Double) -> CGFloat { size.height * (1 - max(0, min(1, (value - reading.lowerBound) / (reading.upperBound - reading.lowerBound)))) }
            for segment in reading.segments {
                if reading.style == "bars" {
                    for point in segment {
                        let left = x(point.seconds), top = y(point.value)
                        context.fill(Path(CGRect(x: left, y: top, width: max(1, x(point.endSeconds ?? point.seconds) - left), height: max(1, size.height - top))), with: .color(color(reading).opacity(0.8)))
                    }
                } else {
                    var line = Path()
                    for (index, point) in segment.enumerated() {
                        let position = CGPoint(x: x(point.seconds), y: y(point.value))
                        if index == 0 { line.move(to: position) } else { line.addLine(to: position) }
                    }
                    context.stroke(line, with: .color(color(reading)), lineWidth: 1)
                    if segment.count == 1, let point = segment.first { context.fill(Path(ellipseIn: CGRect(x: x(point.seconds) - 1, y: y(point.value) - 1, width: 2, height: 2)), with: .color(color(reading))) }
                }
            }
        }
    }
}

struct GarminPulseHealthWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: PulseWidgetSnapshot.widgetKind, provider: PulseWidgetProvider()) { PulseSystemWidgetView(entry: $0) }
            .configurationDisplayName("Garmin Pulse 健康指标")
            .description("显示所选指标和更新时间。打开应用设置内容，点按查看全天趋势。")
            .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
    }
}

@main struct GarminPulseWidgetBundle: WidgetBundle {
    var body: some Widget { GarminPulseHealthWidget() }
}

import SwiftUI
import AppKit

enum PulseTheme {
    static var textScale: Double = 1.1
    static func adaptive(_ light: NSColor, _ dark: NSColor) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light })
    }
    static let background = adaptive(NSColor(red: 0.95, green: 0.97, blue: 0.965, alpha: 1), NSColor(red: 0.065, green: 0.079, blue: 0.089, alpha: 1))
    static let surface = adaptive(.white, NSColor(red: 0.105, green: 0.12, blue: 0.135, alpha: 1))
    static let mint = adaptive(NSColor(red: 0.08, green: 0.43, blue: 0.30, alpha: 1), NSColor(red: 0.54, green: 0.94, blue: 0.75, alpha: 1))
    static let secondary = Color.secondary
    static let onAccent = adaptive(.white, .black)
    static func font(size: CGFloat, weight: Font.Weight = .regular, design: Font.Design = .default) -> Font {
        .system(size: max(11, size * textScale), weight: weight, design: design)
    }
    static func color(_ kind: MetricKind) -> Color {
        switch kind {
        case .heartRate: return adaptive(.systemRed, NSColor(red: 1, green: 0.49, blue: 0.59, alpha: 1))
        case .stress: return adaptive(.systemOrange, NSColor(red: 0.98, green: 0.77, blue: 0.42, alpha: 1))
        case .bodyBattery: return adaptive(.systemBlue, NSColor(red: 0.61, green: 0.76, blue: 1, alpha: 1))
        default: return kind.group == .solar ? adaptive(NSColor(red: 0.67, green: 0.41, blue: 0.02, alpha: 1), NSColor(red: 1, green: 0.79, blue: 0.35, alpha: 1)) : mint
        }
    }
}

struct PulseCard<Content: View>: View {
    var content: Content
    init(@ViewBuilder content: () -> Content) { self.content = content() }
    var body: some View {
        content.padding(20).frame(maxWidth: .infinity, alignment: .leading)
            .background(PulseTheme.surface)
            .clipShape(RoundedRectangle(cornerRadius: 18))
            .overlay(RoundedRectangle(cornerRadius: 18).stroke(Color.primary.opacity(0.06), lineWidth: 1))
    }
}

struct StatusDot: View {
    var active: Bool
    var body: some View { Circle().fill(active ? PulseTheme.mint : Color.primary.opacity(0.25)).frame(width: 6, height: 6) }
}

struct MetricCard: View {
    @ObservedObject var model: AppModel
    let kind: MetricKind
    var compact = false
    var body: some View {
        Button { model.openMetric(kind) } label: {
        VStack(alignment: .leading, spacing: compact ? 9 : 14) {
            HStack {
                MetricIcon(kind: kind).foregroundStyle(PulseTheme.color(kind))
                Text(L10n.text(kind.title)).font(PulseTheme.font(size: compact ? 11 : 13, weight: .medium)).foregroundStyle(PulseTheme.secondary).lineLimit(2)
                Spacer(minLength: 0)
                if !compact { Image(systemName: "chevron.right").font(PulseTheme.font(size: 8)).foregroundStyle(PulseTheme.secondary) }
            }
            HStack(alignment: .firstTextBaseline, spacing: 5) {
                Text(L10n.text(model.display(kind))).font(PulseTheme.font(size: compact ? 24 : model.cardSize.readingSize, weight: .medium, design: .rounded)).monospacedDigit().lineLimit(1).minimumScaleFactor(0.6)
                if !compact { Text(L10n.text(kind.unit)).font(PulseTheme.font(size: 10)).foregroundStyle(PulseTheme.secondary) }
            }
            if compact { Text(L10n.text(kind.unit)).font(PulseTheme.font(size: 8)).foregroundStyle(PulseTheme.secondary) }
            if let timeline = kind.timelineKind {
                MetricMiniChart(series: model.series(for: kind), kind: timeline, axes: !compact).equatable().frame(height: compact ? 28 : model.cardSize.chartHeight)
            } else if !compact {
                Text(L10n.text("当日汇总 · 点击查看")).font(PulseTheme.font(size: 11)).foregroundStyle(PulseTheme.secondary).frame(height: model.cardSize.chartHeight, alignment: .bottom)
            }
            if !compact {
                Text(L10n.text(model.detail(kind))).font(PulseTheme.font(size: 11)).foregroundStyle(PulseTheme.secondary).lineLimit(2).frame(minHeight: 32 * model.fontScale, alignment: .top)
            }
        }
        .padding(compact ? 14 : model.cardSize.padding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(PulseTheme.surface)
        .clipShape(RoundedRectangle(cornerRadius: compact ? 12 : 18))
        .overlay(RoundedRectangle(cornerRadius: compact ? 12 : 18).stroke(Color.primary.opacity(0.055), lineWidth: 1))
        }.buttonStyle(.plain).help(L10n.text("点击查看\(kind.title)的详细记录"))
    }
}

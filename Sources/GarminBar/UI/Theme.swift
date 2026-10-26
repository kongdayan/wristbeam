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
    static let secondary = Color(nsColor: .secondaryLabelColor)
    static let separator = Color(nsColor: .separatorColor)
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
    @Environment(\.colorSchemeContrast) private var contrast
    var content: Content
    init(@ViewBuilder content: () -> Content) { self.content = content() }
    var body: some View {
        content.padding(20).frame(maxWidth: .infinity, alignment: .leading)
            .background(PulseTheme.surface)
            .clipShape(RoundedRectangle(cornerRadius: 18))
            .overlay(RoundedRectangle(cornerRadius: 18).strokeBorder(contrast == .increased ? Color.primary : PulseTheme.separator, lineWidth: 1).allowsHitTesting(false))
    }
}

struct StatusDot: View {
    var active: Bool
    var body: some View { Circle().fill(active ? PulseTheme.mint : Color.primary.opacity(0.25)).frame(width: 6, height: 6) }
}

/// Shared nonmodal feedback: symbols and text carry meaning without relying on color.
struct PulseNotice: View {
    let text: String
    var symbol = "info.circle"
    var warning = false
    var body: some View {
        Label(L10n.text(text), systemImage: symbol)
            .font(PulseTheme.font(size: 12))
            .foregroundStyle(warning ? Color.primary : PulseTheme.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .padding(12).frame(maxWidth: .infinity, alignment: .leading)
            .background(warning ? Color.orange.opacity(0.1) : Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 10))
            .accessibilityElement(children: .combine)
    }
}

struct PulseEmptyState: View {
    let title: String
    let detail: String
    var symbol = "tray"
    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: symbol).font(.system(size: 28)).foregroundStyle(PulseTheme.mint).accessibilityHidden(true)
            Text(L10n.text(title)).font(PulseTheme.font(size: 16, weight: .semibold))
            Text(L10n.text(detail)).font(PulseTheme.font(size: 13)).foregroundStyle(PulseTheme.secondary)
                .multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
        }.padding(.vertical, 28).padding(.horizontal, 16).frame(maxWidth: .infinity)
            .accessibilityElement(children: .combine)
    }
}

/// Wrap independent actions instead of compressing or clipping their labels.
struct PulseFlowLayout: Layout {
    var spacing: CGFloat = 8
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        arrangement(width: proposal.width, subviews: subviews).size
    }
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let result = arrangement(width: bounds.width, subviews: subviews)
        for (index, frame) in result.frames.enumerated() {
            subviews[index].place(at: CGPoint(x: bounds.minX + frame.minX, y: bounds.minY + frame.minY),
                                  anchor: .topLeading, proposal: ProposedViewSize(frame.size))
        }
    }
    private func arrangement(width: CGFloat?, subviews: Subviews) -> (size: CGSize, frames: [CGRect]) {
        let limit = max(1, width ?? .greatestFiniteMagnitude)
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0, used: CGFloat = 0
        var frames: [CGRect] = []
        for view in subviews {
            let ideal = view.sizeThatFits(.unspecified)
            let size = view.sizeThatFits(ProposedViewSize(width: min(limit, ideal.width), height: nil))
            if x > 0, x + size.width > limit { x = 0; y += rowHeight + spacing; rowHeight = 0 }
            frames.append(CGRect(origin: CGPoint(x: x, y: y), size: size))
            used = max(used, x + size.width); x += size.width + spacing; rowHeight = max(rowHeight, size.height)
        }
        return (CGSize(width: used, height: y + rowHeight), frames)
    }
}

struct MetricCard: View {
    @ObservedObject var model: AppModel
    let kind: MetricKind
    var compact = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorSchemeContrast) private var contrast
    @State private var hovering = false
    @FocusState private var focused: Bool
    var body: some View {
        Button { model.openMetric(kind) } label: {
        VStack(alignment: .leading, spacing: compact ? 9 : 10) {
            HStack {
                MetricIcon(kind: kind).foregroundStyle(PulseTheme.color(kind))
                Text(L10n.text(kind.title)).font(PulseTheme.font(size: compact ? 11 : 13, weight: .medium)).foregroundStyle(PulseTheme.secondary).lineLimit(2)
                Spacer(minLength: 0)
                if !compact, let sample = model.metrics[kind] {
                    Text(sample.timestamp, format: (kind.isOvernightHRV || sample.timestampIsMeasurement == false) ? .dateTime.month().day() : .dateTime.hour().minute())
                        .font(PulseTheme.font(size: 9)).monospacedDigit().foregroundStyle(PulseTheme.secondary)
                        .fixedSize().help(L10n.text("更新时间") + " · " + sample.timestamp.formatted())
                }
            }
            HStack(alignment: .firstTextBaseline, spacing: 5) {
                Text(L10n.text(model.display(kind))).font(PulseTheme.font(size: compact ? 24 : model.cardSize.readingSize, weight: .medium, design: .rounded)).monospacedDigit().lineLimit(1).minimumScaleFactor(0.6)
                if !compact { Text(L10n.text(kind.unit)).font(PulseTheme.font(size: 10)).foregroundStyle(PulseTheme.secondary) }
            }
            if compact { Text(L10n.text(kind.unit)).font(PulseTheme.font(size: 8)).foregroundStyle(PulseTheme.secondary) }
            if kind.isOvernightHRV {
                if kind == .hrvStatus {
                    Text(L10n.text("夜间状态 · 点击查看基线")).font(PulseTheme.font(size: 10)).foregroundStyle(PulseTheme.secondary).frame(height: compact ? 28 : model.cardSize.chartHeight, alignment: .bottom)
                } else {
                    HRVTrendMiniChart(series: model.series(for: kind)).frame(height: compact ? 28 : model.cardSize.chartHeight)
                }
            } else if let timeline = kind.timelineKind {
                MetricMiniChart(series: model.series(for: kind), kind: timeline, axes: !compact).equatable().frame(height: compact ? 28 : model.cardSize.chartHeight)
            } else if !compact {
                Text(L10n.text("当日汇总 · 点击查看")).font(PulseTheme.font(size: 11)).foregroundStyle(PulseTheme.secondary).frame(height: model.cardSize.chartHeight, alignment: .bottom)
            }
            if !compact, model.isStale(kind) || model.metricNotes[kind] != nil {
                Label(L10n.text(model.metricNotes[kind] ?? "读数已过期"), systemImage: "clock.badge.exclamationmark")
                    .font(PulseTheme.font(size: 10)).foregroundStyle(PulseTheme.secondary).lineLimit(2)
            }
        }
        .padding(compact ? 14 : model.cardSize.padding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(PulseTheme.surface, in: RoundedRectangle(cornerRadius: compact ? 12 : 18))
        .overlay {
            RoundedRectangle(cornerRadius: compact ? 12 : 18)
                .strokeBorder(focused ? PulseTheme.mint : contrast == .increased ? Color.primary : hovering ? PulseTheme.mint.opacity(0.65) : PulseTheme.separator,
                              lineWidth: focused ? 2 : 1).allowsHitTesting(false)
        }
        }.buttonStyle(.plain).focused($focused)
            .onHover { hovering = $0 }
            .animation(reduceMotion ? nil : .easeOut(duration: 0.16), value: hovering)
            .help(L10n.text("点击查看\(kind.title)的详细记录"))
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(L10n.text(kind.title) + " · " + L10n.text(model.display(kind)) + " " + L10n.text(kind.unit))
            .accessibilityValue(accessibilityStatus)
            .accessibilityHint(L10n.text("查看详情"))
    }
    private var accessibilityStatus: String {
        var parts: [String] = []
        if let sample = model.metrics[kind] { parts.append(sample.timestamp.formatted(.dateTime.month().day().hour().minute().locale(L10n.locale))) }
        if model.isStale(kind) { parts.append(L10n.text("读数已过期")) }
        if let note = model.metricNotes[kind] { parts.append(L10n.text(note)) }
        return parts.joined(separator: " · ")
    }
}

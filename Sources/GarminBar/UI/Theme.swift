import SwiftUI
import AppKit

enum PulseTheme {
    static var textScale: Double = 1.1
    static let sectionSpacing: CGFloat = 20
    static let warning = Color.orange
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
    var emphasized = false
    @State private var hovered = false
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
        .background {
            RoundedRectangle(cornerRadius: compact ? 12 : 18)
                .fill(PulseTheme.surface)
                .overlay {
                    RoundedRectangle(cornerRadius: compact ? 12 : 18)
                        .stroke(hovered ? PulseTheme.mint.opacity(0.5) : emphasized ? PulseTheme.color(kind).opacity(0.25) : Color.primary.opacity(0.07), lineWidth: 1)
                }
        }
        }.buttonStyle(PulseRowButtonStyle()).onHover { hovered = $0 }
            .help(L10n.text("点击查看\(kind.title)的详细记录"))
    }
}


/// Shared row feedback; native bordered controls remain the default for actions.
struct PulseRowButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View { Row(configuration: configuration) }
    private struct Row: View {
        let configuration: Configuration
        @Environment(\.isEnabled) private var enabled
        @Environment(\.isFocused) private var focused
        @State private var hovered = false
        var body: some View {
            configuration.label.contentShape(RoundedRectangle(cornerRadius: 10))
                .background(PulseTheme.mint.opacity(enabled && (hovered || configuration.isPressed) ? 0.09 : 0), in: RoundedRectangle(cornerRadius: 10))
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(focused ? PulseTheme.mint : .clear, lineWidth: 2))
                .opacity(enabled ? 1 : 0.5).onHover { hovered = $0 }
        }
    }
}

struct PulseBackButton: View {
    let title: String
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            Label(L10n.text(title), systemImage: "chevron.left")
                .font(PulseTheme.font(size: 14, weight: .medium)).padding(.vertical, 4)
        }.buttonStyle(PulseButtonStyle()).controlSize(.large).help(L10n.text("返回") + " · ⌘[")
    }
}

struct PulseEmptyState<Actions: View>: View {
    let title: String
    let detail: String
    let symbol: String
    @ViewBuilder var actions: () -> Actions
    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: symbol).font(PulseTheme.font(size: 26)).foregroundStyle(PulseTheme.secondary)
            Text(L10n.text(title)).font(PulseTheme.font(size: 16, weight: .semibold))
            if !detail.isEmpty { Text(L10n.text(detail)).font(PulseTheme.font(size: 12)).foregroundStyle(PulseTheme.secondary).multilineTextAlignment(.center) }
            HStack(spacing: 10) { actions() }.buttonStyle(.bordered)
        }.padding(24).frame(maxWidth: .infinity)
    }
}

/// Shared action styling with quiet hover, keyboard focus and reduced-motion support.
struct PulseButtonStyle: ButtonStyle {
    var prominent = false
    var card = false
    func makeBody(configuration: Configuration) -> some View {
        StyledButton(configuration: configuration, prominent: prominent, card: card)
    }
    private struct StyledButton: View {
        let configuration: Configuration
        let prominent: Bool
        let card: Bool
        @State private var hovered = false
        @Environment(\.isEnabled) private var enabled
        @Environment(\.isFocused) private var focused
        @Environment(\.accessibilityReduceMotion) private var reduceMotion
        private var shape: RoundedRectangle {
            RoundedRectangle(cornerRadius: card ? 18 : 12, style: .continuous)
        }
        var body: some View {
            configuration.label
                .font(PulseTheme.font(size: 12, weight: card ? .regular : .medium))
                .foregroundStyle(prominent ? PulseTheme.onAccent : Color.primary)
                .padding(.horizontal, 14).padding(.vertical, card ? 14 : 9)
                .background(prominent ? PulseTheme.mint : Color.primary.opacity(hovered && enabled ? 0.075 : 0.035), in: shape)
                .overlay(shape.strokeBorder(prominent ? Color.clear : Color.primary.opacity(hovered && enabled ? 0.12 : 0.045), lineWidth: 1))
                .overlay(shape.strokeBorder(focused ? PulseTheme.mint : .clear, lineWidth: 2))
                .contentShape(shape)
                .opacity(enabled ? (configuration.isPressed ? 0.72 : 1) : 0.4)
                .onHover { hovered = $0 }
                .animation(reduceMotion ? nil : .easeOut(duration: 0.16), value: hovered)
                .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: configuration.isPressed)
        }
    }
}

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
    static let secondary = Color(nsColor: .secondaryLabelColor)
    static let separator = Color(nsColor: .separatorColor)
    static let onAccent = adaptive(.white, .black)
    static let destructive = adaptive(NSColor(red: 0.70, green: 0.12, blue: 0.08, alpha: 1), NSColor(red: 1, green: 0.54, blue: 0.50, alpha: 1))
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

/// Main-window rhythm: page edges, section breaks, and related content groups.
enum PulseLayout {
    static let pageInset: CGFloat = 24
    static let sectionGap: CGFloat = 24
    static let groupGap: CGFloat = 12
    static let itemGap: CGFloat = 8
    static let dashboardMaximumWidth: CGFloat = 1120
    static let metricMaximumWidth: CGFloat = 360
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
    var emphasized = false
    @Environment(\.colorSchemeContrast) private var contrast
    @State private var hovered = false
    var body: some View {
        Button { model.openMetric(kind) } label: {
        VStack(alignment: .leading, spacing: compact ? 9 : 10) {
            HStack(alignment: .top) {
                MetricIcon(kind: kind).foregroundStyle(PulseTheme.color(kind))
                Text(L10n.text(kind.title)).font(PulseTheme.font(size: compact ? 11 : 13, weight: .medium)).foregroundStyle(PulseTheme.secondary)
                    .lineLimit(2, reservesSpace: !compact)
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
            if !compact, let sample = model.metrics[kind] {
                Text(L10n.text(sample.origin == .watch ? "手表读数" : sample.origin == .cloud ? "云端记录" : "估算读数"))
                    .font(PulseTheme.font(size: 11)).foregroundStyle(PulseTheme.secondary)
            }
            if !compact, model.isStale(kind) || model.metricNotes[kind] != nil {
                Label(L10n.text(model.metricNotes[kind] ?? "读数已过期"), systemImage: "clock.badge.exclamationmark")
                    .font(PulseTheme.font(size: 10)).foregroundStyle(PulseTheme.secondary).lineLimit(2)
            }
        }
        .padding(compact ? 14 : model.cardSize.padding)
        .frame(maxWidth: .infinity, maxHeight: compact ? nil : .infinity, alignment: .topLeading)
        .background {
            RoundedRectangle(cornerRadius: compact ? 12 : 18)
                .fill(PulseTheme.surface)
                .overlay {
                    RoundedRectangle(cornerRadius: compact ? 12 : 18)
                        .strokeBorder(contrast == .increased ? Color.primary : hovered ? PulseTheme.mint.opacity(0.65) : emphasized ? PulseTheme.color(kind).opacity(0.4) : PulseTheme.separator, lineWidth: 1).allowsHitTesting(false)
                }
        }
        }.buttonStyle(PulseRowButtonStyle()).onHover { hovered = $0 }
            .help(L10n.text("点击查看\(kind.title)的详细记录"))
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(L10n.text(kind.title) + " · " + L10n.text(model.display(kind)) + " " + L10n.text(kind.unit))
            .accessibilityValue(accessibilityStatus).accessibilityHint(L10n.text("查看详情"))
    }
    private var accessibilityStatus: String {
        var parts: [String] = []
        if let sample = model.metrics[kind] {
            parts.append(L10n.text(sample.origin == .watch ? "手表读数" : sample.origin == .cloud ? "云端记录" : "估算读数"))
            if kind.isOvernightHRV {
                parts.append(L10n.format("夜间记录日期：{0}", sample.timestamp.formatted(.dateTime.month().day().locale(L10n.locale))))
            } else {
                parts.append(L10n.format(sample.timestampIsMeasurement == false ? "同步时间：{0}" : "记录时间：{0}", sample.timestamp.formatted(.dateTime.month().day().hour().minute().locale(L10n.locale))))
            }
        }
        if model.isStale(kind) { parts.append(L10n.text("读数已过期")) }
        if let note = model.metricNotes[kind] { parts.append(L10n.text(note)) }
        return parts.joined(separator: " · ")
    }
}


/// Shared row feedback for navigation and wide click targets.
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
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(focused ? PulseTheme.mint : .clear, lineWidth: 2).allowsHitTesting(false))
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
                .font(PulseTheme.font(size: 13, weight: .medium))
                .padding(.horizontal, 8).padding(.vertical, 6).frame(minHeight: 32)
        }.buttonStyle(PulseRowButtonStyle()).help(L10n.text("返回") + " · ⌘[")
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
            PulseFlowLayout(spacing: 10) { actions() }.buttonStyle(PulseButtonStyle())
        }.padding(24).frame(maxWidth: .infinity)
    }
}

/// Shared action styling with quiet hover, keyboard focus and reduced-motion support.
struct PulseButtonStyle: ButtonStyle {
    var prominent = false
    var card = false
    var compact = false
    func makeBody(configuration: Configuration) -> some View {
        StyledButton(configuration: configuration, prominent: prominent, card: card, compact: compact)
    }
    private struct StyledButton: View {
        let configuration: Configuration
        let prominent: Bool
        let card: Bool
        let compact: Bool
        @State private var hovered = false
        @Environment(\.isEnabled) private var enabled
        @Environment(\.isFocused) private var focused
        @Environment(\.controlSize) private var controlSize
        @Environment(\.accessibilityReduceMotion) private var reduceMotion
        private var minimumHeight: CGFloat { compact ? 28 : controlSize == .large ? 40 : 32 }
        private var actionColor: Color { configuration.role == .destructive ? PulseTheme.destructive : .primary }
        private var shape: RoundedRectangle {
            RoundedRectangle(cornerRadius: card ? 18 : 7, style: .continuous)
        }
        var body: some View {
            configuration.label
                .font(PulseTheme.font(size: 12, weight: card ? .regular : .medium))
                .foregroundStyle(prominent ? PulseTheme.onAccent : actionColor)
                .padding(.horizontal, compact ? 9 : 12).padding(.vertical, card ? 14 : controlSize == .large && !compact ? 9 : 5)
                .frame(minWidth: compact ? 28 : 32, minHeight: minimumHeight)
                .background(prominent ? PulseTheme.mint : Color.primary.opacity(hovered && enabled ? 0.075 : 0.035), in: shape)
                .overlay(shape.strokeBorder(prominent ? Color.clear : Color.primary.opacity(hovered && enabled ? 0.12 : 0.045), lineWidth: 1).allowsHitTesting(false))
                .overlay(shape.strokeBorder(focused ? PulseTheme.mint : .clear, lineWidth: 2).allowsHitTesting(false))
                .contentShape(shape)
                .opacity(enabled ? (configuration.isPressed ? 0.72 : 1) : 0.4)
                .onHover { hovered = $0 }
                .animation(reduceMotion ? nil : .easeOut(duration: 0.16), value: hovered)
                .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: configuration.isPressed)
        }
    }
}


/// Header and chevron share one keyboard-accessible button. Content controls are
/// siblings of that button, so editing a field never collapses its section.
struct PulseDisclosure<Content: View>: View {
    let title: String
    private let expansion: Binding<Bool>?
    @State private var expanded: Bool
    private let content: Content
    init(_ title: String, isExpanded: Binding<Bool>? = nil, initiallyExpanded: Bool = false,
         @ViewBuilder content: () -> Content) {
        self.title = title
        self.expansion = isExpanded
        self._expanded = State(initialValue: initiallyExpanded)
        self.content = content()
    }
    var body: some View {
        DisclosureGroup(isExpanded: expansion ?? $expanded) { content } label: { Text(title) }
            .disclosureGroupStyle(PulseDisclosureStyle())
    }
}

struct PulseDisclosureStyle: DisclosureGroupStyle {
    func makeBody(configuration: Configuration) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Button { configuration.isExpanded.toggle() } label: {
                HStack(spacing: 12) {
                    configuration.label.multilineTextAlignment(.leading)
                    Spacer(minLength: 8)
                    Image(systemName: configuration.isExpanded ? "chevron.up" : "chevron.down")
                        .font(PulseTheme.font(size: 12, weight: .semibold))
                        .foregroundStyle(PulseTheme.secondary).accessibilityHidden(true)
                }
                .font(PulseTheme.font(size: 13, weight: .medium))
                .padding(.horizontal, 14).padding(.vertical, 12)
                .frame(maxWidth: .infinity, minHeight: 48, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(PulseRowButtonStyle())
            .accessibilityValue(L10n.text(configuration.isExpanded ? "已展开" : "已收起"))
            if configuration.isExpanded {
                Divider().padding(.horizontal, 14)
                VStack(alignment: .leading, spacing: 12) { configuration.content }
                    .frame(maxWidth: .infinity, alignment: .leading).padding(14)
            }
        }
        .background(PulseTheme.surface, in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(.primary.opacity(0.08)).allowsHitTesting(false))
    }
}


/// Checkbox cells keep the complete table cell clickable, including whitespace.
struct PulseSelectionToggleStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        Button { configuration.isOn.toggle() } label: {
            Image(systemName: configuration.isOn ? "checkmark.square.fill" : "square")
                .font(PulseTheme.font(size: 17))
                .foregroundStyle(configuration.isOn ? PulseTheme.mint : PulseTheme.secondary)
                .frame(maxWidth: .infinity, minHeight: 44).contentShape(Rectangle())
        }.buttonStyle(PulseRowButtonStyle())
            .accessibilityValue(L10n.text(configuration.isOn ? "已选择" : "未选择"))
            .accessibilityRepresentation {
                Toggle(isOn: configuration.$isOn) { configuration.label }.toggleStyle(.checkbox)
            }
    }
}

// Content-only empty states share the same styling without inventing actions.
extension PulseEmptyState where Actions == EmptyView {
    init(title: String, detail: String, symbol: String = "tray") {
        self.init(title: title, detail: detail, symbol: symbol, actions: { EmptyView() })
    }
}

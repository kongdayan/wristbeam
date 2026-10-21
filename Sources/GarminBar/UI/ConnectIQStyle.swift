import SwiftUI

struct ConnectIQSurface<Content: View>: View {
    private let content: Content
    init(@ViewBuilder content: () -> Content) { self.content = content() }
    var body: some View {
        content.padding(20).frame(maxWidth: .infinity, alignment: .leading)
            .background(PulseTheme.surface, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 24, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.055), lineWidth: 1))
    }
}

/// Local to Connect IQ: rounded hit regions, quiet hover feedback and reduced-motion support.
struct ConnectIQButtonStyle: ButtonStyle {
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
                .contentShape(shape)
                .opacity(enabled ? (configuration.isPressed ? 0.72 : 1) : 0.4)
                .onHover { hovered = $0 }
                .animation(reduceMotion ? nil : .easeOut(duration: 0.16), value: hovered)
                .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: configuration.isPressed)
        }
    }
}

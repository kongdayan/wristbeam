import SwiftUI

struct PulseMenuChoice<Value: Hashable>: Identifiable {
    let title: String
    let value: Value
    var id: Value { value }
    init(_ title: String, _ value: Value) { self.title = title; self.value = value }
}

/// Native menu selection with a SwiftUI label: macOS 26's menu-style Picker
/// can render its generated title black in a dark window.
struct PulseMenuPicker<Value: Hashable>: View {
    let title: String
    @Binding var selection: Value
    let choices: [PulseMenuChoice<Value>]
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.isEnabled) private var enabled
    @Environment(\.colorSchemeContrast) private var contrast
    @FocusState private var focused: Bool
    @State private var hovered = false
    init(_ title: String, selection: Binding<Value>, choices: [PulseMenuChoice<Value>]) {
        self.title = title; self._selection = selection; self.choices = choices
    }
    private var selectedTitle: String { choices.first { $0.value == selection }?.title ?? "—" }
    private var labelColor: Color { colorScheme == .dark ? .white : .black }
    var body: some View {
        Menu {
            Picker(L10n.text(title), selection: $selection) {
                ForEach(choices) { Text($0.title).tag($0.value) }
            }.pickerStyle(.inline).labelsHidden()
        } label: {
            HStack(spacing: 8) {
                Text(selectedTitle).foregroundStyle(labelColor).lineLimit(1)
                Spacer(minLength: 0)
                Image(systemName: "chevron.up.chevron.down")
                    .font(PulseTheme.font(size: 9, weight: .semibold))
                    .foregroundStyle(labelColor.opacity(0.65)).accessibilityHidden(true)
            }.font(PulseTheme.font(size: 12)).padding(.horizontal, 10).padding(.vertical, 5).frame(minHeight: 32)
        }.menuStyle(.borderlessButton).menuIndicator(.hidden).buttonStyle(.borderless)
            .background(Color.primary.opacity(hovered && enabled ? 0.075 : 0.035), in: RoundedRectangle(cornerRadius: 7))
            .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(contrast == .increased ? Color.primary : PulseTheme.separator, lineWidth: 1).allowsHitTesting(false))
            .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(focused ? PulseTheme.mint : .clear, lineWidth: 2).allowsHitTesting(false))
            .focused($focused).onHover { hovered = $0 }.opacity(enabled ? 1 : 0.45)
            .accessibilityLabel(L10n.text(title))
            .accessibilityValue(selectedTitle).help(selectedTitle)
    }
}

import AppKit
import SwiftUI

struct PulseMenuChoice<Value: Hashable>: Identifiable {
    let title: String
    let value: Value
    var id: Value { value }
    init(_ title: String, _ value: Value) { self.title = title; self.value = value }
}

/// AppKit owns single-selection, menu keyboard behavior and popup rendering.
/// Explicit font and appearance avoid macOS 26 SwiftUI menu-title regressions.
struct PulseMenuPicker<Value: Hashable>: NSViewRepresentable {
    let title: String
    @Binding var selection: Value
    let choices: [PulseMenuChoice<Value>]
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.isEnabled) private var enabled

    init(_ title: String, selection: Binding<Value>, choices: [PulseMenuChoice<Value>]) {
        self.title = title; self._selection = selection; self.choices = choices
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSPopUpButton {
        let button = NSPopUpButton(frame: .zero, pullsDown: false)
        button.target = context.coordinator
        button.action = #selector(Coordinator.choose(_:))
        button.controlSize = .regular
        button.menu?.autoenablesItems = false
        button.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return button
    }

    func updateNSView(_ button: NSPopUpButton, context: Context) {
        context.coordinator.parent = self
        let titles = choices.map(\.title)
        if button.itemTitles != titles || context.coordinator.values != choices.map(\.value) {
            button.removeAllItems()
            button.addItems(withTitles: titles)
            context.coordinator.values = choices.map(\.value)
        }
        button.selectItem(at: choices.firstIndex { $0.value == selection } ?? -1)
        button.font = .systemFont(ofSize: max(11, 12 * PulseTheme.textScale))
        button.appearance = NSAppearance(named: colorScheme == .dark ? .darkAqua : .aqua)
        button.contentTintColor = .labelColor
        button.isEnabled = enabled && !choices.isEmpty
        button.setAccessibilityLabel(L10n.text(title))
        button.toolTip = button.title
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSPopUpButton, context: Context) -> CGSize? {
        let intrinsic = nsView.intrinsicContentSize
        return CGSize(width: proposal.width ?? intrinsic.width, height: max(32, intrinsic.height))
    }

    final class Coordinator: NSObject {
        var parent: PulseMenuPicker
        var values: [Value] = []
        init(_ parent: PulseMenuPicker) { self.parent = parent }
        @objc func choose(_ sender: NSPopUpButton) {
            guard values.indices.contains(sender.indexOfSelectedItem) else { return }
            parent.selection = values[sender.indexOfSelectedItem]
        }
    }
}

import AppKit
import SwiftUI

/// One native window shell shared by the application and the CI window fixture.
@MainActor
final class PulseSettingsWindow: NSWindow, NSWindowDelegate {
    var onPreviewSnapshot: (() -> Void)?
    var restoresAccessoryOnClose = false

    static func title(for model: AppModel) -> String {
        let page = model.detailMetric.map { L10n.text($0.title) }
            ?? (model.page == .settings ? L10n.text("常规设置") : model.page.title)
        return model.preview ? "\(page) · WristBeam Demo" : page
    }

    static func make(model: AppModel) -> PulseSettingsWindow {
        let window = PulseSettingsWindow(contentRect: NSRect(x: 0, y: 0, width: 1020, height: 740),
            styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = title(for: model)
        window.titleVisibility = .visible
        window.titlebarAppearsTransparent = false
        window.toolbarStyle = .unified
        window.collectionBehavior = [.fullScreenPrimary]
        window.backgroundColor = NSColor(PulseTheme.background)
        window.minSize = NSSize(width: 760, height: 600)
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: SettingsRootView(model: model))
        window.delegate = window
        window.restoresAccessoryOnClose = !model.preview
        return window
    }

    func presentMainWindow() {
        NSApp.setActivationPolicy(.regular)
        makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func windowWillClose(_ notification: Notification) {
        if restoresAccessoryOnClose { NSApp.setActivationPolicy(.accessory) }
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if modifiers == .command, event.charactersIgnoringModifiers == "s", let onPreviewSnapshot {
            onPreviewSnapshot(); return true
        }
        return super.performKeyEquivalent(with: event)
    }
}

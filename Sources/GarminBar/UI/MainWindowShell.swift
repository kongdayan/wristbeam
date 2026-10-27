import AppKit
import SwiftUI

/// One native window shell shared by the application and the CI window fixture.
@MainActor
final class PulseSettingsWindow: NSWindow, NSWindowDelegate {
    var onPreviewSnapshot: (() -> Void)?
    var restoresAccessoryOnClose = false

    static func make(model: AppModel) -> PulseSettingsWindow {
        let window = PulseSettingsWindow(contentRect: NSRect(x: 0, y: 0, width: 1020, height: 740),
            styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = model.preview ? "WristBeam Demo" : L10n.text("腕映")
        window.titleVisibility = .visible
        window.titlebarAppearsTransparent = false
        window.toolbarStyle = .unified
        window.collectionBehavior = [.fullScreenPrimary]
        window.backgroundColor = NSColor(PulseTheme.background)
        window.minSize = NSSize(width: 880, height: 640)
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

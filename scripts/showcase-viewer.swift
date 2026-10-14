import AppKit
import WebKit

@main struct ShowcaseMain {
    @MainActor static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.regular)
        let delegate = ShowcaseDelegate()
        app.delegate = delegate
        withExtendedLifetime(delegate) { app.run() }
    }
}
@MainActor final class ShowcaseDelegate: NSObject, NSApplicationDelegate {
    private var window: NSWindow?
    private var webView: WKWebView?
    private var outputDirectory: URL?
    func applicationDidFinishLaunching(_ notification: Notification) {
        guard let path = Bundle.main.object(forInfoDictionaryKey: "ShowcaseHTML") as? String else { return }
        let url = URL(fileURLWithPath: path)
        let configuration = WKWebViewConfiguration(); configuration.websiteDataStore = .nonPersistent()
        let view = WKWebView(frame: NSRect(x: 0, y: 0, width: 1280, height: 860), configuration: configuration)
        webView = view
        outputDirectory = url.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("images")
        view.autoresizingMask = [.width, .height]
        let menu = NSMenu(); let rootItem = NSMenuItem(); let appMenu = NSMenu()
        let reload = NSMenuItem(title: "Reload", action: #selector(WKWebView.reload(_:)), keyEquivalent: "r"); reload.target = view
        appMenu.addItem(reload)
        let export = NSMenuItem(title: "Save showcase image", action: #selector(saveScene), keyEquivalent: "s"); export.target = self
        appMenu.addItem(export)
        appMenu.addItem(NSMenuItem(title: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        rootItem.submenu = appMenu; menu.addItem(rootItem); NSApp.mainMenu = menu
        view.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent().deletingLastPathComponent())
        let panel = ShowcaseWindow(contentRect: view.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        panel.title = "WristBeam Showcase"; panel.contentView = view; panel.center()
        panel.isReleasedWhenClosed = false; window = panel
        panel.makeKeyAndOrderFront(nil); panel.makeFirstResponder(view)
        NSApp.activate(ignoringOtherApps: true)
    }
    @objc private func saveScene() {
        guard let view = webView, let directory = outputDirectory else { return }
        view.evaluateJavaScript("document.querySelector('.scene.active').id") { [weak self] value, _ in
            guard let name = value as? String, ["hero", "menu", "themes", "settings"].contains(name) else { return }
            let configuration = WKSnapshotConfiguration()
            configuration.rect = CGRect(x: 0, y: 0, width: 1280, height: 860)
            configuration.snapshotWidth = 1280
            view.takeSnapshot(with: configuration) { picture, _ in
                guard let picture, let tiff = picture.tiffRepresentation, let bitmap = NSBitmapImageRep(data: tiff),
                      let png = bitmap.representation(using: .png, properties: [:]) else { return }
                do {
                    try png.write(to: directory.appendingPathComponent("showcase-\(name).png"), options: .atomic)
                    self?.window?.title = "WristBeam Showcase · Saved \(name) · \(bitmap.pixelsWide) × \(bitmap.pixelsHigh)"
                } catch { self?.window?.title = "WristBeam Showcase · Export failed" }
            }
        }
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}
final class ShowcaseWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

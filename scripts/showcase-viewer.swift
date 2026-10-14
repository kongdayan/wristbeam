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
    private var sourceURL: URL?
    func applicationDidFinishLaunching(_ notification: Notification) {
        guard let path = Bundle.main.object(forInfoDictionaryKey: "ShowcaseHTML") as? String else { return }
        let url = URL(fileURLWithPath: path)
        sourceURL = url
        let configuration = WKWebViewConfiguration(); configuration.websiteDataStore = .nonPersistent()
        let view = WKWebView(frame: NSRect(x: 0, y: 0, width: 1280, height: 860), configuration: configuration)
        webView = view
        outputDirectory = url.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("images")
        view.autoresizingMask = [.width, .height]
        let menu = NSMenu(); let rootItem = NSMenuItem(); let appMenu = NSMenu()
        let reload = NSMenuItem(title: "Reload", action: #selector(WKWebView.reload(_:)), keyEquivalent: "r"); reload.target = view
        appMenu.addItem(reload)
        let chinese = NSMenuItem(title: "Chinese showcase", action: #selector(showChinese), keyEquivalent: "z"); chinese.target = self
        appMenu.addItem(chinese)
        let english = NSMenuItem(title: "English showcase", action: #selector(showEnglish), keyEquivalent: "e"); english.target = self
        appMenu.addItem(english)
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
        view.evaluateJavaScript("({scene: document.querySelector('.scene.active').id, language: document.documentElement.lang})") { [weak self] value, _ in
            guard let result = value as? [String: String], let name = result["scene"], ["hero", "menu", "themes", "settings"].contains(name) else { return }
            let suffix = result["language"]?.hasPrefix("zh") == true ? "-zh" : ""
            let configuration = WKSnapshotConfiguration()
            configuration.rect = CGRect(x: 0, y: 0, width: 1280, height: 860)
            configuration.snapshotWidth = 1280
            view.takeSnapshot(with: configuration) { picture, _ in
                guard let picture, let tiff = picture.tiffRepresentation, let bitmap = NSBitmapImageRep(data: tiff),
                      let png = bitmap.representation(using: .png, properties: [:]) else { return }
                do {
                    try png.write(to: directory.appendingPathComponent("showcase-\(name)\(suffix).png"), options: .atomic)
                    self?.window?.title = "WristBeam Showcase · Saved \(name) · \(bitmap.pixelsWide) × \(bitmap.pixelsHigh)"
                } catch { self?.window?.title = "WristBeam Showcase · Export failed" }
            }
        }
    }
    @objc private func showChinese() { loadLanguage(chinese: true) }
    @objc private func showEnglish() { loadLanguage(chinese: false) }
    private func loadLanguage(chinese: Bool) {
        guard let sourceURL, let webView else { return }
        let directory = sourceURL.deletingLastPathComponent()
        webView.loadFileURL(directory.appendingPathComponent(chinese ? "index.zh-CN.html" : "index.html"), allowingReadAccessTo: directory.deletingLastPathComponent())
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}
final class ShowcaseWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

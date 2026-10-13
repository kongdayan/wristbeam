import AppKit
import SwiftUI
import Combine

@main
enum GarminPulseMain {
    @MainActor static func main() {
        if PulseLocalControl.handleCommandLine() { return }
        let app = NSApplication.shared
        let delegate = PulseAppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        withExtendedLifetime(delegate) { app.run() }
    }
}

@MainActor
final class PulseAppDelegate: NSObject, NSApplicationDelegate {
    let model = AppModel()
    private var statusItem: NSStatusItem!
    private var popover: NSPopover!
    private var settingsWindow: NSWindow?
    private var floatingPanel: NSPanel?
    private var subscriptions: Set<AnyCancellable> = []
    private var controlObserver: NSObjectProtocol?

    func applicationDidFinishLaunching(_ notification: Notification) {
        if PulseRuntime.isPreview { model.enablePreview() }
        model.onOpenSettings = { [weak self] page in self?.showSettings(page) }
        model.onFloatingChange = { [weak self] enabled in self?.setFloating(enabled) }
        model.onFloatingLayoutChange = { [weak self] in
            guard let self, self.model.floatingEnabled else { return }; self.setFloating(true)
        }
        model.onAppearanceChange = { [weak self] in self?.applyAppearance() }
        model.onQuit = { NSApplication.shared.terminate(nil) }
        model.updater.canInstall = { [weak self] in self?.model.uploads.isSyncing == false && self?.model.bluetooth.isTransferringFiles == false && self?.model.preview == false }
        model.updater.onConfirmation = { [weak self] in self?.confirmUpdate() }
        controlObserver = DistributedNotificationCenter.default().addObserver(forName: PulseLocalControl.notification, object: nil, queue: .main) { [weak self] notification in
            guard let command = notification.userInfo?["command"] as? String,
                  let request = notification.userInfo?["request"] as? String, UUID(uuidString: request) != nil else { return }
            Task { @MainActor [weak self] in
                guard let self, !self.model.preview else { return }
                if command == "recent" { self.model.syncRecentActivity() }
                else if command == "sync" { self.model.syncNow() }
                else if command == "scan" { self.model.bluetooth.beginPairing() }
                else if command == "reconnect" { self.model.bluetooth.reconnectSaved() }
                else if command == "retry-protocol" { self.model.bluetooth.retryProtocol() }
                else if command == "forget-watch" { self.model.bluetooth.forgetSavedWatch() }
                else if command == "refresh-metrics" { self.model.refreshMetricsNow() }
                else if command == "connect", let rawID = notification.userInfo?["watchID"] as? String, let id = UUID(uuidString: rawID),
                        self.model.bluetooth.nearby.contains(where: { $0.id == id && $0.offersGarmin && Date().timeIntervalSince($0.lastSeen) < 45 }) { self.model.bluetooth.connect(id) }
                else { return }
                self.model.lastControlRequest = request
                self.model.writeRuntimeState()
            }
        }
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            button.target = self; button.action = #selector(togglePopover(_:))
            button.font = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium)
            button.toolTip = "Garmin Pulse · 心率、身体压力与步数"
        }
        popover = NSPopover(); popover.behavior = .transient
        popover.contentSize = NSSize(width: 420, height: 500)
        popover.contentViewController = NSHostingController(rootView: MenuPopover(model: model))
        model.objectWillChange.receive(on: RunLoop.main).sink { [weak self] in
            DispatchQueue.main.async { self?.statusItem.button?.title = self?.model.menuText ?? "Garmin Pulse" }
        }.store(in: &subscriptions)
        statusItem.button?.title = model.menuText
        if model.floatingEnabled { setFloating(true) }
        showSettings(.overview)
        if !model.preview && model.bluetooth.autoReconnect { model.bluetooth.reconnectSaved() }
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(wokeUp), name: NSWorkspace.didWakeNotification, object: nil)
        if !model.preview {
            Task { await model.updater.check(automatic: true) }
            Timer.publish(every: 3600, on: .main, in: .common).autoconnect().sink { [weak self] _ in Task { await self?.model.updater.check(automatic: true) } }.store(in: &subscriptions)
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool { showSettings(.overview); return true }
    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls {
            if let destination = PulseWidgetLink.destination(url), let kind = MetricKind(rawValue: destination.metricID) {
                model.openMetric(kind, day: destination.day)
                break
            }
        }
    }

    @objc private func togglePopover(_ sender: Any?) {
        guard let button = statusItem.button else { return }
        if popover.isShown { popover.performClose(sender) }
        else { popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY); NSApp.activate(ignoringOtherApps: true) }
    }

    func showSettings(_ page: AppPage) {
        model.page = page; popover?.performClose(nil)
        if settingsWindow == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1020, height: 740), styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
            window.title = "Garmin Pulse"
            window.titlebarAppearsTransparent = true
            window.backgroundColor = NSColor(PulseTheme.background)
            window.minSize = NSSize(width: 880, height: 640)
            window.isReleasedWhenClosed = false
            window.contentView = NSHostingView(rootView: SettingsRootView(model: model))
            window.center(); window.setFrameAutosaveName("GarminPulseSettings")
            settingsWindow = window
        }
        applyAppearance(); settingsWindow?.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
    }

    func setFloating(_ enabled: Bool) {
        if !enabled { floatingPanel?.orderOut(nil); return }
        if floatingPanel == nil {
            let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: model.floatingWidth, height: model.floatingHeight), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            panel.title = "Garmin Pulse 浮动指标"
            panel.isFloatingPanel = true; panel.level = .floating
            panel.isOpaque = false; panel.backgroundColor = .clear; panel.hasShadow = true
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            panel.isMovableByWindowBackground = true; panel.hidesOnDeactivate = false
            panel.contentView = NSHostingView(rootView: FloatingPulseView(model: model))
            if let screen = NSScreen.main {
                panel.setFrameOrigin(NSPoint(x: screen.visibleFrame.maxX - model.floatingWidth - 30, y: screen.visibleFrame.maxY - model.floatingHeight - 30))
            }
            panel.setFrameAutosaveName("GarminPulseFloating")
            floatingPanel = panel
        }
        if let panel = floatingPanel, abs(panel.frame.height - model.floatingHeight) > 0.5 || abs(panel.frame.width - model.floatingWidth) > 0.5 {
            panel.setFrame(NSRect(x: panel.frame.minX, y: panel.frame.maxY - model.floatingHeight, width: model.floatingWidth, height: model.floatingHeight), display: true)
        }
        applyAppearance()
        floatingPanel?.orderFrontRegardless()
    }

    @objc private func wokeUp() { if model.bluetooth.autoReconnect && !model.preview { model.bluetooth.reconnectSaved() } }

    private func confirmUpdate() {
        guard let release = model.updater.release, model.updater.available, !model.updater.isInstalling else { return }
        showSettings(.updates)
        guard let window = settingsWindow, window.attachedSheet == nil else { return }
        let alert = NSAlert()
        alert.messageText = L10n.format("发现新版本 {0}", release.tagName)
        alert.informativeText = L10n.text(model.updater.installable ? "确认后下载并校验安装包，完成后自动重启。账户授权、显示设置和本地数据会保留。" : "此版本没有适合本机的安装包，请在 GitHub 查看详情。")
        alert.addButton(withTitle: L10n.text(model.updater.installable ? "下载并升级" : "查看版本说明"))
        alert.addButton(withTitle: L10n.text("稍后"))
        alert.addButton(withTitle: L10n.text("跳过此版本"))
        alert.beginSheetModal(for: window) { [weak self] response in
            guard let self else { return }
            if response == .alertFirstButtonReturn {
                if self.model.updater.installable { Task { await self.model.updater.installConfirmed() } }
                else { NSWorkspace.shared.open(release.htmlURL) }
            } else if response == .alertThirdButtonReturn { self.model.updater.skipVersion() }
        }
    }

    private func applyAppearance() {
        let appearance = model.appearance == .system ? nil : NSAppearance(named: model.appearance == .light ? .aqua : .darkAqua)
        settingsWindow?.appearance = appearance; floatingPanel?.appearance = appearance
        popover?.appearance = appearance
        statusItem?.button?.toolTip = L10n.text("Garmin Pulse · 心率、身体压力与步数")
        floatingPanel?.title = L10n.text("Garmin Pulse 浮动指标")
    }
}

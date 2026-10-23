import AppKit
import Combine
import SwiftUI
import WebKit

struct ConnectIQSettingsEditorContext {
    let identity: String
    let request: URLRequest
    let appName: String
}

struct ConnectIQSettingsSheet: View {
    @ObservedObject var model: AppModel
    @StateObject private var controller: ConnectIQSettingsController
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme
    private let face: GFDIInstalledWatchFace
    private let onSaved: () -> Void
    init(model: AppModel, face: GFDIInstalledWatchFace, onSaved: @escaping () -> Void = {}) {
        self.model = model; self.face = face
        self.onSaved = onSaved
        _controller = StateObject(wrappedValue: ConnectIQSettingsController(cloud: model.cloud, bluetooth: model.bluetooth, face: face))
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let request = controller.editorRequest {
                ConnectIQSettingsView(
                    context: .init(identity: controller.identity, request: request, appName: model.connectIQ.apps[face.id]?.localizedName ?? controller.appName),
                    onSubmit: {
                        try await controller.save(jsonData: $0)
                        onSaved()
                    },
                    onDismiss: { controller.cancel(); dismiss() })
                    .id(controller.identity)
            } else {
                HStack {
                    Text(model.connectIQ.apps[face.id]?.localizedName ?? face.name).font(.headline)
                    Spacer()
                    Button(L10n.text("关闭")) { controller.cancel(); dismiss() }
                }
                Spacer()
                if controller.busy { ProgressView().frame(maxWidth: .infinity) }
                Text(L10n.text(controller.status)).frame(maxWidth: .infinity).textSelection(.enabled)
                if !controller.busy {
                    Button(L10n.text("重试")) { Task { await controller.load(dark: colorScheme == .dark) } }
                        .frame(maxWidth: .infinity)
                        .disabled(model.preview)
                }
                Spacer()
            }
            if controller.editorRequest != nil && !controller.status.isEmpty {
                Text(L10n.text(controller.status)).font(PulseTheme.font(size: 11)).foregroundStyle(PulseTheme.secondary)
            }
        }
        .buttonStyle(PulseButtonStyle())
        .padding(20).frame(width: 700, height: 680)
        .background(PulseTheme.background)
        .interactiveDismissDisabled()
        .task { if !model.preview { await controller.load(dark: colorScheme == .dark) } }
        .onChange(of: model.bluetooth.isConnected) { connected in if !connected { controller.cancel(); dismiss() } }
        .onChange(of: model.cloud.isAuthenticated) { authenticated in if !authenticated { controller.cancel(); dismiss() } }
        .onChange(of: model.watchUnitID) { id in if UInt32(id) != face.unitID { controller.cancel(); dismiss() } }
        .onChange(of: model.cloud.accountGUID) { _ in controller.cancel(); dismiss() }
        .onChange(of: model.cloud.deviceId) { _ in controller.cancel(); dismiss() }
        .onChange(of: model.cloud.region) { _ in controller.cancel(); dismiss() }
        .onChange(of: model.cloud.networkEnabled) { enabled in if !enabled { controller.cancel(); dismiss() } }
        .onDisappear { controller.cancel() }
    }
}

struct ConnectIQSettingsView: View {
    let context: ConnectIQSettingsEditorContext
    let onSubmit: (Data) async throws -> Void
    let onDismiss: () -> Void
    @StateObject private var commands = ConnectIQSettingsWebCommands()
    @State private var saving = false
    @State private var confirmExit = false
    @State private var status = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Button { back() } label: {
                    Label(L10n.text(commands.nested ? "返回" : "关闭"), systemImage: commands.nested ? "chevron.left" : "xmark")
                }.disabled(saving)
                Text(context.appName).font(PulseTheme.font(size: 17, weight: .semibold)).lineLimit(1)
                Spacer()
                if !commands.nested {
                    Button(L10n.text(saving ? "正在保存…" : "保存到手表")) { submit() }
                        .buttonStyle(PulseButtonStyle(prominent: true))
                        .disabled(saving || !commands.ready || commands.loading || commands.error != nil)
                }
            }
            ZStack {
                ConnectIQSettingsWebEditor(request: context.request, identity: context.identity, commands: commands,
                                           onReady: {}, onError: { _ in })
                    .allowsHitTesting(!saving)
                if commands.loading || saving {
                    ProgressView().padding(16).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
                }
            }
            .background(PulseTheme.surface)
            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.06), lineWidth: 1))
            if let error = commands.error {
                HStack {
                    Text(L10n.text(error)).foregroundStyle(.orange)
                    Spacer()
                    Button(L10n.text("重试")) { commands.reload() }.disabled(saving)
                }.font(PulseTheme.font(size: 12))
            }
            if !status.isEmpty { Text(L10n.text(status)).font(PulseTheme.font(size: 12)).textSelection(.enabled) }
        }
        .onExitCommand { if !saving { back() } }
        .confirmationDialog(L10n.text("退出设置？"), isPresented: $confirmExit, titleVisibility: .visible) {
            Button(L10n.text("放弃更改"), role: .destructive) { onDismiss() }
            Button(L10n.text("继续编辑"), role: .cancel) {}
        } message: { Text(L10n.text("尚未保存的修改将被丢弃。")) }
    }
    private func submit() {
        guard !saving, commands.ready, !commands.loading, !commands.nested else { return }
        saving = true; status = ""
        Task { @MainActor in
            defer { saving = false }
            do {
                guard let json = try await commands.submit() else { status = "请检查页面中标出的设置"; return }
                try await onSubmit(json)
                onDismiss()
            } catch {
                if !(error is CancellationError) { status = "保存未能确认，请重新读取手表状态" }
            }
        }
    }
    private func back() {
        guard !saving else { return }
        if !commands.ready || commands.error != nil { onDismiss(); return }
        Task { @MainActor in
            do { let handled = try await commands.back(); if !handled { confirmExit = true } }
            catch { confirmExit = true }
        }
    }
}

/// A narrow native-to-web command interface. No script message handlers are registered.
@MainActor final class ConnectIQSettingsWebCommands: ObservableObject {
    @Published fileprivate(set) var loading = true
    @Published fileprivate(set) var ready = false
    @Published fileprivate(set) var nested = false
    @Published fileprivate(set) var error: String?
    fileprivate weak var webView: WKWebView?
    fileprivate var reloadAction: (() -> Void)?
    func submit() async throws -> Data? {
        guard ready, !loading, let webView else { throw EditorError.unavailable }
        let value = try await webView.evaluateJavaScript("handleFormSubmit()")
        guard !(value is NSNull), let text = value as? String else { return nil }
        guard let data = text.data(using: .utf8), data.count <= 1024 * 1024,
              (try JSONSerialization.jsonObject(with: data)) is [String: Any] else { throw EditorError.invalidForm }
        return data
    }
    func back() async throws -> Bool {
        guard ready, let webView else { return false }
        return (try await webView.evaluateJavaScript("handleBack()")) as? Bool == true
    }
    func reload() {
        guard let reloadAction else { return }
        error = nil; ready = false; loading = true
        reloadAction()
    }
    fileprivate enum EditorError: Error { case unavailable, invalidForm }
}

struct ConnectIQSettingsWebEditor: NSViewRepresentable {
    let request: URLRequest
    let identity: String
    @ObservedObject var commands: ConnectIQSettingsWebCommands
    let onReady: () -> Void
    let onError: (String) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeNSView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.hideScrollIndicators()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = true
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
        let view = WKWebView(frame: .zero, configuration: configuration)
        view.customUserAgent = "GarminPulse/0.1 (macOS)"
        view.navigationDelegate = context.coordinator; view.uiDelegate = context.coordinator
        view.allowsBackForwardNavigationGestures = false
        commands.webView = view
        commands.reloadAction = { [weak coordinator = context.coordinator, weak view] in
            guard let view else { return }
            coordinator?.start(view)
        }
        context.coordinator.start(view)
        return view
    }
    func updateNSView(_ view: WKWebView, context: Context) {
        // The enclosing .id(identity) owns page lifetime; published UI updates never reload edits.
        context.coordinator.parent = self
    }
    static func dismantleNSView(_ view: WKWebView, coordinator: Coordinator) {
        coordinator.active = false
        view.stopLoading(); view.navigationDelegate = nil; view.uiDelegate = nil
        coordinator.parent.commands.webView = nil
        coordinator.parent.commands.reloadAction = nil
    }

    @MainActor final class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate {
        var parent: ConnectIQSettingsWebEditor
        var active = true
        private var navigationRevision = 0
        private let policy: ConnectIQSettingsEditorPolicy.NavigationPolicy?
        init(_ parent: ConnectIQSettingsWebEditor) {
            self.parent = parent; policy = parent.request.url.flatMap(ConnectIQSettingsEditorPolicy.NavigationPolicy.init)
        }
        func start(_ view: WKWebView) {
            guard let policy else { fail(); return }
            guard let json = try? ConnectIQSettingsEditorPolicy.contentRuleListJSON(host: policy.host) else { fail(); return }
            WKContentRuleListStore.default().compileContentRuleList(forIdentifier: "WristBeam.ConnectIQ.Settings." + policy.host, encodedContentRuleList: json) { [weak self, weak view] list, _ in
                Task { @MainActor in
                    guard let self, self.active, let view else { return }
                    guard let list else { self.fail(); return }
                    view.configuration.userContentController.add(list)
                    view.load(self.parent.request)
                }
            }
        }
        private func fail() {
            guard active else { return }
            parent.commands.ready = false; parent.commands.loading = false
            let message = "设置页面未能加载，请重试"
            parent.commands.error = message; parent.onError(message)
        }
        func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            guard let url = action.request.url, let policy else { decisionHandler(.cancel); return }
            if action.targetFrame?.isMainFrame != false, policy.allowsPage(url) { decisionHandler(.allow); return }
            if action.navigationType == .linkActivated, action.request.httpMethod == "GET",
               ["https", "http"].contains(url.scheme ?? ""), url.user == nil, url.password == nil {
                NSWorkspace.shared.open(url)
            }
            decisionHandler(.cancel)
        }
        func webView(_ webView: WKWebView, decidePolicyFor response: WKNavigationResponse, decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void) {
            guard response.isForMainFrame, let http = response.response as? HTTPURLResponse,
                  let url = http.url, policy?.allowsPage(url) == true,
                  (200..<300).contains(http.statusCode), response.canShowMIMEType else { fail(); decisionHandler(.cancel); return }
            decisionHandler(.allow)
        }
        func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
            navigationRevision += 1
            parent.commands.loading = true; parent.commands.ready = false; parent.commands.error = nil
        }
        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            guard let url = webView.url, policy?.allowsPage(url) == true else { fail(); return }
            parent.commands.nested = url.lastPathComponent != "edit"
            let revision = navigationRevision
            let readiness = parent.commands.nested
                ? "typeof handleBack === 'function' && typeof jQuery === 'function'"
                : "typeof handleFormSubmit === 'function' && typeof handleBack === 'function' && typeof jQuery === 'function'"
            webView.evaluateJavaScript(readiness) { [weak self] value, _ in
                guard let self, self.active, self.navigationRevision == revision else { return }
                guard value as? Bool == true else { self.fail(); return }
                self.parent.commands.loading = false; self.parent.commands.ready = true
                self.parent.commands.error = nil; self.parent.onReady()
            }
        }
        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { fail() }
        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            if (error as NSError).code != NSURLErrorCancelled { fail() }
        }
        func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration, for action: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
            guard active, let url = action.request.url else { return nil }
            if policy?.allowsPage(url) == true { webView.load(action.request) }
            else if action.request.httpMethod == "GET", ["http", "https"].contains(url.scheme ?? ""), url.user == nil, url.password == nil {
                // WebKit blocks script-created windows without a user gesture.
                NSWorkspace.shared.open(url)
            }
            return nil
        }
        func webViewWebContentProcessDidTerminate(_ webView: WKWebView) { fail() }
        func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String,
                     initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping () -> Void) {
            guard active, let window = webView.window, let url = frame.request.url,
                  policy?.allowsPage(url) == true else { completionHandler(); return }
            let alert = settingsAlert(message)
            alert.addButton(withTitle: L10n.text("确定"))
            alert.beginSheetModal(for: window) { _ in completionHandler() }
        }
        func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String,
                     initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping (Bool) -> Void) {
            guard active, let window = webView.window, let url = frame.request.url,
                  policy?.allowsPage(url) == true else { completionHandler(false); return }
            let alert = settingsAlert(message)
            alert.addButton(withTitle: L10n.text("确定"))
            alert.addButton(withTitle: L10n.text("取消"))
            alert.beginSheetModal(for: window) { [weak self] response in
                completionHandler(self?.active == true && response == .alertFirstButtonReturn)
            }
        }
        func webView(_ webView: WKWebView, runJavaScriptTextInputPanelWithPrompt prompt: String,
                     defaultText: String?, initiatedByFrame frame: WKFrameInfo,
                     completionHandler: @escaping (String?) -> Void) {
            guard active, let window = webView.window, let url = frame.request.url,
                  policy?.allowsPage(url) == true else { completionHandler(nil); return }
            let alert = settingsAlert(prompt)
            alert.addButton(withTitle: L10n.text("确定"))
            alert.addButton(withTitle: L10n.text("取消"))
            let input = NSTextField(string: defaultText ?? "")
            input.frame = NSRect(x: 0, y: 0, width: 320, height: 24)
            alert.accessoryView = input
            alert.beginSheetModal(for: window) { [weak self] response in
                completionHandler(self?.active == true && response == .alertFirstButtonReturn ? input.stringValue : nil)
            }
        }
        private func settingsAlert(_ message: String) -> NSAlert {
            let alert = NSAlert()
            alert.messageText = L10n.text("表盘设置")
            alert.informativeText = message
            return alert
        }
    }

}

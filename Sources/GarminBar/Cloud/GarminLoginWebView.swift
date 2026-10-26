import AppKit
import SwiftUI
import WebKit

/// Credentials and MFA remain on Garmin's HTTPS page; the app receives only its service ticket.
struct GarminLoginWebView: NSViewRepresentable {
    @ObservedObject var cloud: GarminChinaCloud
    @Binding var isLoading: Bool

    func makeCoordinator() -> Coordinator { Coordinator(cloud: cloud, isLoading: $isLoading) }

    func makeNSView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.userContentController.add(context.coordinator, name: "GMNEventHandler")
        let view = WKWebView(frame: .zero, configuration: configuration)
        view.navigationDelegate = context.coordinator
        view.uiDelegate = context.coordinator
        view.allowsBackForwardNavigationGestures = true
        context.coordinator.revision = cloud.loginRevision
        if cloud.networkEnabled { view.load(URLRequest(url: cloud.makeLoginURL())) }
        return view
    }

    func updateNSView(_ view: WKWebView, context: Context) {
        context.coordinator.cloud = cloud; context.coordinator.isLoading = $isLoading
        guard cloud.networkEnabled else { view.stopLoading(); return }
        if context.coordinator.revision != cloud.loginRevision {
            context.coordinator.revision = cloud.loginRevision
            view.load(URLRequest(url: cloud.makeLoginURL()))
        }
        if cloud.isAuthenticated { view.stopLoading() }
    }

    static func dismantleNSView(_ view: WKWebView, coordinator: Coordinator) {
        view.stopLoading()
        view.configuration.userContentController.removeScriptMessageHandler(forName: "GMNEventHandler")
        view.navigationDelegate = nil
        view.uiDelegate = nil
    }

    @MainActor
    final class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate, WKScriptMessageHandler {
        var cloud: GarminChinaCloud
        var revision = UUID()
        var isLoading: Binding<Bool>
        init(cloud: GarminChinaCloud, isLoading: Binding<Bool>) { self.cloud = cloud; self.isLoading = isLoading }
        func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) { isLoading.wrappedValue = true }
        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { isLoading.wrappedValue = false }

        func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
            let origin = message.frameInfo.securityOrigin
            guard message.name == "GMNEventHandler", origin.protocol == "https", origin.host.lowercased() == "sso.\(cloud.region.domain)",
                  origin.port == 0 || origin.port == 443 else { return }
            let event: [String: Any]?
            if let object = message.body as? [String: Any] { event = object }
            else if let text = message.body as? String, let data = text.data(using: .utf8) {
                event = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            } else { event = nil }
            guard let event else { return }
            let service = GarminChinaURLPolicy.serviceURL(mode: cloud.loginMode, region: cloud.region)
            if let callback = GarminChinaURLPolicy.callbackURL(fromSSOEvent: event, expectedService: service) {
                cloud.handleNavigation(callback)
            } else if event["eventType"] as? String == "COMMUNICATION",
                      let data = event["data"] as? [String: Any], let communication = data["communication"] as? [String: Any],
                      let text = communication["message"] as? String, !text.isEmpty {
                cloud.loginCommunication(text)
            }
        }

        func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                     decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            guard cloud.networkEnabled, let url = navigationAction.request.url else { decisionHandler(.cancel); return }
            if cloud.handleNavigation(url) { decisionHandler(.cancel); return }
            if GarminChinaURLPolicy.isTrusted(url, region: cloud.region) || url.absoluteString == "about:blank" {
                decisionHandler(.allow)
            } else {
                // Terms/support links may leave CN; they never receive a native service ticket or token.
                if navigationAction.navigationType == .linkActivated, url.scheme == "https" { NSWorkspace.shared.open(url) }
                decisionHandler(.cancel)
            }
        }

        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            isLoading.wrappedValue = false
            guard (error as NSError).code != NSURLErrorCancelled else { return }
            cloud.loginPageFailed(error)
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            isLoading.wrappedValue = false
            guard (error as NSError).code != NSURLErrorCancelled else { return }
            cloud.loginPageFailed(error)
        }

        func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                     for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
            if cloud.networkEnabled, let url = navigationAction.request.url {
                if cloud.handleNavigation(url) { return nil }
                if GarminChinaURLPolicy.isTrusted(url, region: cloud.region) { webView.load(navigationAction.request) }
                else if url.scheme == "https" { NSWorkspace.shared.open(url) }
            }
            return nil
        }

        func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String,
                     initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping () -> Void) {
            let alert = NSAlert()
            alert.messageText = cloud.region.title
            alert.informativeText = message
            alert.addButton(withTitle: "好")
            if let window = webView.window { alert.beginSheetModal(for: window) { _ in completionHandler() } }
            else { alert.runModal(); completionHandler() }
        }

        func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String,
                     initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping (Bool) -> Void) {
            let alert = NSAlert()
            alert.messageText = cloud.region.title
            alert.informativeText = message
            alert.addButton(withTitle: "继续")
            alert.addButton(withTitle: "取消")
            if let window = webView.window { alert.beginSheetModal(for: window) { completionHandler($0 == .alertFirstButtonReturn) } }
            else { completionHandler(alert.runModal() == .alertFirstButtonReturn) }
        }
    }
}

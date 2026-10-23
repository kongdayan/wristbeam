import WebKit

extension WKWebViewConfiguration {
    /// Hide page and nested-container indicators without changing overflow or input handling.
    func hideScrollIndicators() {
        userContentController.addUserScript(WKUserScript(source: """
            (() => {
                const style = document.createElement('style');
                style.textContent = `
                    * { scrollbar-width: none !important; }
                    ::-webkit-scrollbar { display: none !important; width: 0 !important; height: 0 !important; }
                `;
                (document.head || document.documentElement).appendChild(style);
            })();
            """, injectionTime: .atDocumentEnd, forMainFrameOnly: false))
    }
}

import SwiftUI
import WebKit

struct MermaidWebView: NSViewRepresentable {
    let source: String
    let zoom: Double

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = true
        configuration.userContentController.add(context.coordinator, name: "mermaidStatus")

        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = context.coordinator
        webView.underPageBackgroundColor = .clear

        guard let htmlURL = Bundle.main.url(forResource: "viewer", withExtension: "html") else {
            webView.loadHTMLString(
                "<h2 style='font-family: -apple-system; padding: 24px'>viewer.html을 찾을 수 없습니다.</h2>",
                baseURL: nil
            )
            return webView
        }

        webView.loadFileURL(
            htmlURL,
            allowingReadAccessTo: htmlURL.deletingLastPathComponent()
        )
        context.coordinator.pendingSource = source
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        webView.pageZoom = 1.0
        context.coordinator.applyZoom(zoom, in: webView)
        context.coordinator.render(source, in: webView)
    }

    static func dismantleNSView(_ webView: WKWebView, coordinator: Coordinator) {
        webView.configuration.userContentController.removeScriptMessageHandler(forName: "mermaidStatus")
        webView.navigationDelegate = nil
    }

    final class Coordinator: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
        var pendingSource = ""
        private var isDocumentLoaded = false
        private var isRuntimeReady = false
        private var lastRenderedSource: String?
        private var pendingZoom = 1.0
        private var lastAppliedZoom: Double?

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation?) {
            isDocumentLoaded = true
            lastRenderedSource = nil
            lastAppliedZoom = nil
            applyZoom(pendingZoom, in: webView)
            render(pendingSource, in: webView)
        }

        func userContentController(
            _ userContentController: WKUserContentController,
            didReceive message: WKScriptMessage
        ) {
            guard
                message.name == "mermaidStatus",
                let payload = message.body as? [String: Any],
                let type = payload["type"] as? String
            else {
                return
            }

            switch type {
            case "ready":
                isRuntimeReady = true
                if let webView = message.webView {
                    applyZoom(pendingZoom, in: webView)
                    render(pendingSource, in: webView)
                }
            case "error":
                let details = payload["message"] as? String ?? "알 수 없는 JavaScript 오류"
                NSLog("[ReviewCanvas] %@", details)
            default:
                break
            }
        }

        func applyZoom(_ zoom: Double, in webView: WKWebView) {
            pendingZoom = zoom
            guard isDocumentLoaded, isRuntimeReady, zoom != lastAppliedZoom else {
                return
            }

            lastAppliedZoom = zoom
            webView.evaluateJavaScript("window.setDiagramZoom(\(zoom));") { _, error in
                if let error {
                    NSLog("[ReviewCanvas] 확대/축소 적용 실패: %@", error.localizedDescription)
                }
            }
        }

        func render(_ source: String, in webView: WKWebView) {
            pendingSource = source
            guard isDocumentLoaded, isRuntimeReady, source != lastRenderedSource else {
                return
            }

            guard
                let encodedData = try? JSONEncoder().encode(source),
                let encodedSource = String(data: encodedData, encoding: .utf8)
            else {
                return
            }

            lastRenderedSource = source
            webView.evaluateJavaScript("window.renderMermaid(\(encodedSource));") { _, error in
                if let error {
                    NSLog("[ReviewCanvas] JavaScript 호출 실패: %@", error.localizedDescription)
                }
            }
        }
    }
}

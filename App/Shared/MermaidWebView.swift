import SwiftUI
import WebKit

#if os(macOS)
import AppKit
#else
import UIKit
#endif

@MainActor
struct MermaidWebView {
    let source: String
    let zoom: Double
    let onGeometryChange: (DiagramViewportGeometry) -> Void
    let onError: (String?) -> Void

    func makeCoordinator() -> MermaidWebCoordinator {
        MermaidWebCoordinator(
            source: source,
            zoom: zoom,
            onGeometryChange: onGeometryChange,
            onError: onError
        )
    }

    fileprivate func makeWebView(coordinator: MermaidWebCoordinator) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = true
        configuration.userContentController.add(coordinator, name: "mermaidStatus")

        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = coordinator
        #if os(macOS)
        webView.underPageBackgroundColor = .clear
        #else
        webView.isOpaque = false
        webView.backgroundColor = .clear
        webView.scrollView.backgroundColor = .clear
        #endif

        coordinator.webView = webView
        coordinator.loadViewer(in: webView)
        return webView
    }

    fileprivate func update(_ webView: WKWebView, coordinator: MermaidWebCoordinator) {
        coordinator.update(
            source: source,
            zoom: zoom,
            onGeometryChange: onGeometryChange,
            onError: onError,
            in: webView
        )
    }

    fileprivate static func dismantle(_ webView: WKWebView, coordinator: MermaidWebCoordinator) {
        webView.configuration.userContentController.removeScriptMessageHandler(forName: "mermaidStatus")
        webView.navigationDelegate = nil
        coordinator.webView = nil
    }
}

#if os(macOS)
extension MermaidWebView: NSViewRepresentable {
    func makeNSView(context: Context) -> WKWebView {
        makeWebView(coordinator: context.coordinator)
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        update(webView, coordinator: context.coordinator)
    }

    static func dismantleNSView(_ webView: WKWebView, coordinator: MermaidWebCoordinator) {
        dismantle(webView, coordinator: coordinator)
    }
}
#else
extension MermaidWebView: UIViewRepresentable {
    func makeUIView(context: Context) -> WKWebView {
        makeWebView(coordinator: context.coordinator)
    }

    func updateUIView(_ webView: WKWebView, context: Context) {
        update(webView, coordinator: context.coordinator)
    }

    static func dismantleUIView(_ webView: WKWebView, coordinator: MermaidWebCoordinator) {
        dismantle(webView, coordinator: coordinator)
    }
}
#endif

@MainActor
final class MermaidWebCoordinator: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
    weak var webView: WKWebView?

    private var pendingSource: String
    private var pendingZoom: Double
    private var onGeometryChange: (DiagramViewportGeometry) -> Void
    private var onError: (String?) -> Void
    private var isDocumentLoaded = false
    private var isRuntimeReady = false
    private var lastRenderedSource: String?
    private var lastAppliedZoom: Double?

    init(
        source: String,
        zoom: Double,
        onGeometryChange: @escaping (DiagramViewportGeometry) -> Void,
        onError: @escaping (String?) -> Void
    ) {
        pendingSource = source
        pendingZoom = zoom
        self.onGeometryChange = onGeometryChange
        self.onError = onError
    }

    func loadViewer(in webView: WKWebView) {
        guard let htmlURL = Bundle.main.url(forResource: "viewer", withExtension: "html") else {
            let message = "viewer.html을 찾을 수 없습니다."
            webView.loadHTMLString(
                "<h2 style='font-family: -apple-system; padding: 24px'>\(message)</h2>",
                baseURL: nil
            )
            onError(message)
            return
        }

        webView.loadFileURL(htmlURL, allowingReadAccessTo: htmlURL.deletingLastPathComponent())
    }

    func update(
        source: String,
        zoom: Double,
        onGeometryChange: @escaping (DiagramViewportGeometry) -> Void,
        onError: @escaping (String?) -> Void,
        in webView: WKWebView
    ) {
        pendingSource = source
        pendingZoom = zoom
        self.onGeometryChange = onGeometryChange
        self.onError = onError
        applyZoom(in: webView)
        render(in: webView)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation?) {
        isDocumentLoaded = true
        lastRenderedSource = nil
        lastAppliedZoom = nil
        applyZoom(in: webView)
        render(in: webView)
    }

    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationAction: WKNavigationAction
    ) async -> WKNavigationActionPolicy {
        guard let url = navigationAction.request.url else {
            return .cancel
        }

        if url.isFileURL || url.scheme == "about" {
            return .allow
        }

        NSLog("[ReviewCanvas] 외부 WebView 이동 차단: %@", url.absoluteString)
        return .cancel
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
            if let webView {
                applyZoom(in: webView)
                render(in: webView)
            }
        case "rendered":
            onError(nil)
        case "geometry":
            guard
                let x = number(payload["x"]),
                let y = number(payload["y"]),
                let width = number(payload["width"]),
                let height = number(payload["height"])
            else {
                return
            }
            let nodes = (payload["nodes"] as? [[String: Any]] ?? []).compactMap { node -> DiagramNodeGeometry? in
                guard
                    let id = node["id"] as? String,
                    let nodeX = number(node["x"]),
                    let nodeY = number(node["y"]),
                    let nodeWidth = number(node["width"]),
                    let nodeHeight = number(node["height"])
                else {
                    return nil
                }
                return DiagramNodeGeometry(
                    id: id,
                    x: nodeX,
                    y: nodeY,
                    width: nodeWidth,
                    height: nodeHeight
                )
            }
            onGeometryChange(
                DiagramViewportGeometry(x: x, y: y, width: width, height: height, nodes: nodes)
            )
        case "error":
            let details = payload["message"] as? String ?? "알 수 없는 Mermaid 오류"
            onError(details)
            NSLog("[ReviewCanvas] %@", details)
        default:
            break
        }
    }

    private func applyZoom(in webView: WKWebView) {
        guard isDocumentLoaded, isRuntimeReady, pendingZoom != lastAppliedZoom else {
            return
        }

        lastAppliedZoom = pendingZoom
        webView.evaluateJavaScript("window.setDiagramZoom(\(pendingZoom)); null;") { _, error in
            if let error {
                NSLog("[ReviewCanvas] 확대/축소 적용 실패: %@", error.localizedDescription)
            }
        }
    }

    private func render(in webView: WKWebView) {
        guard isDocumentLoaded, isRuntimeReady, pendingSource != lastRenderedSource else {
            return
        }

        guard
            let encodedData = try? JSONEncoder().encode(pendingSource),
            let encodedSource = String(data: encodedData, encoding: .utf8)
        else {
            return
        }

        lastRenderedSource = pendingSource
        let script = "(function () { void window.renderMermaid(\(encodedSource)); return null; })();"
        webView.evaluateJavaScript(script) { [weak self] _, error in
            if let error {
                self?.onError(error.localizedDescription)
                NSLog("[ReviewCanvas] JavaScript 호출 실패: %@", error.localizedDescription)
            }
        }
    }

    private func number(_ value: Any?) -> Double? {
        (value as? NSNumber)?.doubleValue
    }
}

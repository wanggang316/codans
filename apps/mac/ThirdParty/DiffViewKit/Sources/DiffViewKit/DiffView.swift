import SwiftUI
import WebKit

/// A read-only, offline web diff renderer. The host owns Git and editor operations.
@MainActor
public struct DiffView: NSViewRepresentable {
    public var document: DiffDocument
    public var options: DiffOptions
    public var onEvent: @MainActor (DiffEvent) -> Void

    public init(document: DiffDocument, options: DiffOptions = .init(),
                onEvent: @escaping @MainActor (DiffEvent) -> Void = { _ in }) {
        self.document = document
        self.options = options
        self.onEvent = onEvent
    }

    public func makeCoordinator() -> Coordinator {
        Coordinator(document: document, options: options, onEvent: onEvent)
    }

    public func makeNSView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
        configuration.userContentController.add(context.coordinator, name: "diffView")
        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = context.coordinator
        context.coordinator.webView = webView
        if let indexURL = Bundle.module.url(forResource: "index", withExtension: "html", subdirectory: "Web") {
            context.coordinator.indexURL = indexURL
            webView.loadFileURL(indexURL, allowingReadAccessTo: indexURL.deletingLastPathComponent())
        } else {
            Task { context.coordinator.fail("Missing bundled web assets. Run npm run build before swift build.") }
        }
        return webView
    }

    public func updateNSView(_ nsView: WKWebView, context: Context) {
        context.coordinator.onEvent = onEvent
        context.coordinator.update(document: document, options: options)
    }

    public static func dismantleNSView(_ nsView: WKWebView, coordinator: Coordinator) {
        coordinator.disposed = true
        nsView.stopLoading()
        nsView.navigationDelegate = nil
        nsView.configuration.userContentController.removeScriptMessageHandler(forName: "diffView")
        coordinator.webView = nil
        coordinator.onEvent = { _ in }
    }

    @MainActor
    public final class Coordinator: NSObject, WKScriptMessageHandler, WKNavigationDelegate {
        weak var webView: WKWebView?
        var indexURL: URL?
        var onEvent: @MainActor (DiffEvent) -> Void
        var document: DiffDocument
        var options: DiffOptions
        var ready = false
        var disposed = false
        var revision = 0

        init(document: DiffDocument, options: DiffOptions, onEvent: @escaping @MainActor (DiffEvent) -> Void) {
            self.document = document
            self.options = options
            self.onEvent = onEvent
        }

        func update(document: DiffDocument, options: DiffOptions) {
            guard self.document != document || self.options != options else { return }
            let optionsChanged = self.options != options
            self.document = document
            self.options = options
            revision += 1
            render(applyOptions: optionsChanged)
        }

        func render(applyOptions: Bool = true) {
            guard ready, !disposed, let webView else { return }
            let expectedRevision = revision
            do {
                let encoder = JSONEncoder()
                let documentValue = try JSONSerialization.jsonObject(with: encoder.encode(document))
                var arguments: [String: Any] = ["document": documentValue]
                if applyOptions {
                    arguments["options"] = try JSONSerialization.jsonObject(with: encoder.encode(options))
                }
                // Document refreshes retain the renderer's user-selected layout/theme.
                // Initial load and an explicit host-options change remain authoritative.
                webView.callAsyncJavaScript(
                    applyOptions ? "return await window.diffView.render(document, options);"
                        : "return await window.diffView.render(document);",
                    arguments: arguments,
                    in: nil, in: .page
                ) { [weak self] result in
                    guard let self, !self.disposed, self.revision == expectedRevision else { return }
                    if case .failure(let error) = result { self.fail(error.localizedDescription) }
                }
            } catch { fail(error.localizedDescription) }
        }

        func fail(_ message: String) {
            guard !disposed else { return }
            onEvent(.init(type: "error", documentID: document.id, message: message))
        }

        public func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
            guard !disposed, message.name == "diffView", message.frameInfo.isMainFrame,
                  message.frameInfo.request.url?.standardizedFileURL == indexURL?.standardizedFileURL,
                  JSONSerialization.isValidJSONObject(message.body),
                  let data = try? JSONSerialization.data(withJSONObject: message.body),
                  let event = try? JSONDecoder().decode(DiffEvent.self, from: data),
                  event.isValid(for: document) else { return }
            if event.type == "ready" {
                guard !ready else { return }
                ready = true
                onEvent(event)
                render()
            } else { onEvent(event) }
        }

        public func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                            decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void) {
            let allowed = navigationAction.targetFrame?.isMainFrame == true
                && navigationAction.request.url?.standardizedFileURL == indexURL?.standardizedFileURL
            decisionHandler(allowed ? .allow : .cancel)
        }

        public func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            fail(error.localizedDescription)
        }

        public func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(10))
                guard let self, !self.disposed, !self.ready else { return }
                self.fail("The bundled renderer did not become ready.")
            }
        }

        public func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            fail(error.localizedDescription)
        }

        public func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
            ready = false
            fail("The web content process terminated. Recreate the view to reload it.")
        }
    }
}

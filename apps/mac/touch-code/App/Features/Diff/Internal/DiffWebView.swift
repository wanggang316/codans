import SwiftUI
import WebKit

/// Notification posted by `DiffPanelView` when the user taps a file in
/// the History-mode picker. Live `DiffWebView` instances subscribe and
/// scroll the rendered diff to the matching file's section. `userInfo`
/// carries `path: String`.
extension Notification.Name {
  static let diffScrollToFileRequested = Notification.Name("diffScrollToFileRequested")
}

/// `NSViewRepresentable` host for the vendored YiTong renderer. Loads
/// `WebAssets/index.html` from the app bundle, registers the
/// `yitongBridge` script-message handler, and forwards
/// (document, configuration) updates as `updateConfiguration` +
/// `renderDocument` JSON envelopes.
struct DiffWebView: NSViewRepresentable {
  let document: DiffDocument
  let configuration: DiffConfiguration
  let onEvent: ((DiffEvent) -> Void)?

  func makeCoordinator() -> DiffWebViewCoordinator {
    let coord = DiffWebViewCoordinator()
    coord.onEvent = onEvent
    return coord
  }

  func makeNSView(context: Context) -> WKWebView {
    let config = WKWebViewConfiguration()
    config.websiteDataStore = .nonPersistent()
    let userContent = WKUserContentController()
    userContent.add(context.coordinator, name: DiffWebViewCoordinator.bridgeName)
    config.userContentController = userContent

    let webView = WKWebView(frame: .zero, configuration: config)
    webView.navigationDelegate = context.coordinator
    #if DEBUG
      if #available(macOS 13.3, *) {
        webView.isInspectable = true
      }
    #endif
    webView.setValue(false, forKey: "drawsBackground")

    // Capture the WebView weakly so the coordinator never strong-holds
    // it; the representable's NSView lifecycle owns it.
    context.coordinator.evaluator = { [weak webView] script in
      webView?.evaluateJavaScript(script, completionHandler: nil)
    }

    // Subscribe to scroll-to-file requests from the History-mode picker.
    // The observer is held by the coordinator so it lives as long as the
    // webview and is cleaned up in `dismantleNSView`.
    context.coordinator.scrollObserver = NotificationCenter.default.addObserver(
      forName: .diffScrollToFileRequested,
      object: nil,
      queue: .main
    ) { [weak coord = context.coordinator] note in
      guard let path = note.userInfo?["path"] as? String else { return }
      // Posted on `.main` (see `queue:` above), so this hop is always safe.
      MainActor.assumeIsolated { coord?.scrollToFile(path: path) }
    }

    if let url = Self.indexURL() {
      webView.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())
    } else {
      onEvent?(.didFail(code: "missing_assets", message: "index.html not found in bundle"))
    }
    return webView
  }

  func updateNSView(_ webView: WKWebView, context: Context) {
    let coord = context.coordinator
    coord.onEvent = onEvent
    do {
      coord.sendEnvelope(try DiffWebViewBridge.encodeSetOptions(configuration), kind: .options)
      coord.sendEnvelope(try DiffWebViewBridge.encodeRender(document, configuration: configuration), kind: .render)
    } catch {
      onEvent?(.didFail(code: "encode_failed", message: String(describing: error)))
    }
  }

  static func dismantleNSView(_ webView: WKWebView, coordinator: DiffWebViewCoordinator) {
    webView.configuration.userContentController.removeScriptMessageHandler(
      forName: DiffWebViewCoordinator.bridgeName
    )
    if let observer = coordinator.scrollObserver {
      NotificationCenter.default.removeObserver(observer)
      coordinator.scrollObserver = nil
    }
    coordinator.resetSendCache()
  }

  private static func indexURL() -> URL? {
    Bundle.main.url(forResource: "index", withExtension: "html")
  }
}

/// Wraps the host→web evaluateJavaScript shape in one place so the
/// coordinator only sees opaque script strings. The JS side decodes the
/// argument with `JSON.parse`, so we serialise the envelope JSON as a
/// JS string literal here.
extension DiffWebViewCoordinator {
  fileprivate func sendEnvelope(_ envelopeJSON: String, kind: SendKind) {
    let escaped =
      envelopeJSON
      .replacingOccurrences(of: "\\", with: "\\\\")
      .replacingOccurrences(of: "\"", with: "\\\"")
      .replacingOccurrences(of: "\n", with: "\\n")
      .replacingOccurrences(of: "\r", with: "\\r")
      .replacingOccurrences(of: "\u{2028}", with: "\\u2028")
      .replacingOccurrences(of: "\u{2029}", with: "\\u2029")
    dispatch(script: "window.__yitongReceiveMessage(\"\(escaped)\")", kind: kind)
  }
}

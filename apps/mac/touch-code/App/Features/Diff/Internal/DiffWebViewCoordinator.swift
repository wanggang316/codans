import Foundation
import WebKit

/// Bridges `WKScriptMessageHandler` callbacks into the SwiftUI host's
/// `onEvent` closure. Holds the closure by value (it's swapped in
/// `updateNSView` whenever the SwiftUI parent re-evaluates) but does NOT
/// retain the `WKWebView` — the representable owns the view, the
/// coordinator only owns wiring.
final class DiffWebViewCoordinator: NSObject, WKScriptMessageHandler, WKNavigationDelegate {
  static let bridgeName = "yitongBridge"

  /// Queue of pending host→web messages while the renderer initialises.
  /// Each entry pairs the script payload with its `SendKind` so we can
  /// dedupe by kind without parsing the JSON. Entries enqueued before the
  /// `ready` event are flushed in arrival order; afterwards the queue
  /// stays empty and we forward immediately.
  private var pendingScripts: [(script: String, kind: SendKind)] = []
  private var ready = false

  /// Last script we actually evaluated for each `SendKind`. Acts as a
  /// post-ready dedupe: SwiftUI's `updateNSView` runs on every parent
  /// re-evaluation (geometry, environment, sibling state) and re-encodes
  /// the same payload; without this cache we'd re-trigger Shiki tokenising
  /// on every appearance toggle or window resize. Reset by
  /// `dismantleNSView` so a fresh WebView mount starts clean.
  private var lastOptionsScript: String?
  private var lastRenderScript: String?

  var onEvent: ((DiffEvent) -> Void)?

  /// Set by the representable on view creation. Weak-ish via closure
  /// capture to avoid the coordinator strong-retaining the WebView.
  var evaluator: ((String) -> Void)?

  /// NotificationCenter observer token for `.diffScrollToFileRequested`.
  /// Owned here so `DiffWebView.dismantleNSView` can detach it cleanly.
  var scrollObserver: NSObjectProtocol?

  /// Run a JS routine that finds the file's section in the rendered
  /// diff and scrolls it into view. Multi-strategy DOM walk because the
  /// vendored YiTong renderer doesn't expose stable file-anchor IDs:
  ///
  /// 1. `data-file` / `data-path` / `id` matching the path directly
  /// 2. Header-ish elements whose text equals or ends with the path
  /// 3. Any leaf element whose text equals the path
  ///
  /// Smooth-scroll into view at block:start so the file's header lands
  /// at the top of the visible area. No-op if the path can't be found.
  func scrollToFile(path: String) {
    let safePath = path
      .replacingOccurrences(of: "\\", with: "\\\\")
      .replacingOccurrences(of: "'", with: "\\'")
    let script = """
      (function(p){
        var t = document.getElementById(p)
          || document.querySelector('[data-file="' + CSS.escape(p) + '"]')
          || document.querySelector('[data-path="' + CSS.escape(p) + '"]');
        if (!t) {
          var headers = document.querySelectorAll(
            'h1, h2, h3, h4, h5, h6, summary, .file-header, .filename, [class*="file"]'
          );
          for (var i = 0; i < headers.length; i++) {
            var tx = (headers[i].textContent || '').trim();
            if (tx === p || tx.endsWith(p)) { t = headers[i]; break; }
          }
        }
        if (!t) {
          var all = document.querySelectorAll('*');
          for (var j = 0; j < all.length; j++) {
            if (all[j].children.length > 0) continue;
            var tx2 = (all[j].textContent || '').trim();
            if (tx2 === p) { t = all[j]; break; }
          }
        }
        if (t) { t.scrollIntoView({behavior:'smooth', block:'start'}); return true; }
        return false;
      })('\(safePath)');
      """
    evaluator?(script)
  }

  func userContentController(
    _ userContentController: WKUserContentController,
    didReceive message: WKScriptMessage
  ) {
    guard let raw = message.body as? String else { return }
    let event: DiffEvent
    do {
      event = try DiffWebViewBridge.decodeEvent(raw)
    } catch {
      event = .didFail(code: "decode_failed", message: String(describing: error))
    }
    if case .didFinishInitialLoad = event {
      ready = true
      flushPending()
    }
    DispatchQueue.main.async { [onEvent] in
      onEvent?(event)
    }
  }

  /// Either evaluates immediately (renderer is ready) or queues until the
  /// `ready` event arrives. Two layers of dedupe:
  ///
  /// 1. Pre-ready (queue): a fresh `.render` evicts any earlier `.render`
  ///    so we don't flash through outdated documents on first paint.
  /// 2. Post-ready (sent-cache): an identical script for the same kind is
  ///    suppressed entirely — guards against `updateNSView` storms from
  ///    SwiftUI re-evaluations re-shipping a byte-identical payload.
  func dispatch(script: String, kind: SendKind) {
    if ready {
      switch kind {
      case .options where lastOptionsScript == script: return
      case .render where lastRenderScript == script: return
      default: break
      }
      evaluator?(script)
      switch kind {
      case .options: lastOptionsScript = script
      case .render: lastRenderScript = script
      }
      return
    }
    if kind == .render {
      pendingScripts.removeAll(where: { $0.kind == .render })
    }
    pendingScripts.append((script, kind))
  }

  /// Test-only hook: flip the `ready` flag and flush any queued scripts
  /// without rigging up a `WKScriptMessage` round-trip. Production code
  /// only ever transitions to `ready` via the inbound `ready` event in
  /// `userContentController(_:didReceive:)`.
  #if DEBUG
    func markReadyForTesting() {
      ready = true
      flushPending()
    }
  #endif

  /// Drops the post-ready send-cache. Called from `DiffWebView.dismantleNSView`
  /// so a fresh WebView mount starts with no remembered scripts.
  func resetSendCache() {
    lastOptionsScript = nil
    lastRenderScript = nil
    pendingScripts.removeAll(keepingCapacity: false)
    ready = false
  }

  private func flushPending() {
    let queued = pendingScripts
    pendingScripts.removeAll(keepingCapacity: false)
    for entry in queued {
      evaluator?(entry.script)
      switch entry.kind {
      case .options: lastOptionsScript = entry.script
      case .render: lastRenderScript = entry.script
      }
    }
  }

  enum SendKind {
    case render
    case options
  }
}

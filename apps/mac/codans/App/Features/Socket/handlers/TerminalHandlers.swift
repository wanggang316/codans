import CodansCore
import CodansIPC
import Foundation
import os

/// Handlers for `terminal.*` — send input into a pane, broadcast across
/// a scope. Backed by an injected `TerminalInputSink` so the router can
/// bind to either the real `TerminalEngine` + `GhosttyRuntime` or a
/// headless test double (or `nil`, in which case these RPCs return
/// `.unsupported`).
@MainActor
public final class TerminalHandlers {
  /// Narrow protocol over the app's input-delivery surface. Implemented
  /// by a small adapter around `GhosttyRuntime.surface(for:).sendInput`;
  /// tests stub it.
  public protocol InputSink: AnyObject, Sendable {
    func sendInput(paneID: PaneID, text: String) -> Bool
    func sendKey(paneID: PaneID, key: IPC.TerminalNamedKey) -> Bool
    func sendRawBytes(paneID: PaneID, bytes: [UInt8]) -> Bool
    /// A live pane may reject input while an interrupted recovery draft remains.
    func inputRejectionReason(for paneID: PaneID) -> String?
    func fanOut(scope: IPC.BroadcastScope, text: String, catalog: Catalog) -> Int
    func readText(paneID: PaneID, extent: ReadExtent) -> String?
    func resetPane(paneID: PaneID) -> Bool
  }

  public enum ReadExtent: String, Codable, Sendable {
    case viewport
    case screen
    case selection
  }

  private let sink: InputSink?
  private let catalog: @MainActor () -> Catalog
  /// Time source for the wait loops (`readText` wait-stable, `sendInput`
  /// wait). Injectable so tests drive them with a virtual clock.
  private let clock: StabilityClock
  /// Whether the pane's shell is running a foreground command — the
  /// foreground-job poller's view, the same bit the tab spinner reads.
  /// `sendInput`'s wait uses it to tell "the command is still running"
  /// from "the screen just stopped changing".
  private let paneIsBusy: @MainActor (PaneID) -> Bool
  private let logger = Logger(subsystem: "com.gumpw.codans.ipc", category: "terminal")

  public init(
    sink: InputSink?,
    catalog: @escaping @MainActor () -> Catalog,
    clock: StabilityClock = SystemStabilityClock(),
    paneIsBusy: @escaping @MainActor (PaneID) -> Bool = { _ in false }
  ) {
    self.sink = sink
    self.catalog = catalog
    self.clock = clock
    self.paneIsBusy = paneIsBusy
  }

  /// Optional completion wait on `sendInput`: poll until the pane is not
  /// busy and its screen has held still for `stableMillis`, or
  /// `timeoutMillis` passes. A command too quick for the busy poller to
  /// notice completes after `graceMillis` of quiet instead.
  public struct SendWaitParams: Codable, Sendable {
    public let timeoutMillis: Int
    public let stableMillis: Int?
    public let graceMillis: Int?

    public init(timeoutMillis: Int, stableMillis: Int? = nil, graceMillis: Int? = nil) {
      self.timeoutMillis = timeoutMillis
      self.stableMillis = stableMillis
      self.graceMillis = graceMillis
    }
  }
  public struct SendInputParams: Codable, Sendable {
    public let paneID: PaneID
    public let text: String
    public let wait: SendWaitParams?
    /// With `wait`, also return the screen lines the command produced.
    public let capture: Bool?

    public init(paneID: PaneID, text: String, wait: SendWaitParams? = nil, capture: Bool? = nil) {
      self.paneID = paneID
      self.text = text
      self.wait = wait
      self.capture = capture
    }
  }
  /// `delivered` is always true on success; the rest is present only when
  /// the request asked to wait.
  public struct SendInputResult: Codable, Sendable {
    public let delivered: Bool
    public let completed: Bool?
    public let waitedMillis: Int?
    public let busyObserved: Bool?
    public let output: String?

    public init(
      delivered: Bool, completed: Bool? = nil, waitedMillis: Int? = nil, busyObserved: Bool? = nil,
      output: String? = nil
    ) {
      self.delivered = delivered
      self.completed = completed
      self.waitedMillis = waitedMillis
      self.busyObserved = busyObserved
      self.output = output
    }
  }
  public func sendInput(_ params: JSONValue) async -> RouterOutcome {
    await Task.yield()
    guard let sink else {
      return .failed(
        .unsupported(reason: "no GhosttyRuntime bound — terminal.sendInput requires the app with panes live"))
    }
    let req: SendInputParams
    do {
      req = try params.decoded(as: SendInputParams.self)
    } catch {
      return .failed(.invalidParams(message: "sendInput requires {paneID, text}", path: nil))
    }
    let before = req.capture == true ? sink.readText(paneID: req.paneID, extent: .screen) : nil
    let ok = sink.sendInput(paneID: req.paneID, text: req.text)
    if !ok { return inputFailure(for: req.paneID, sink: sink) }
    var result = SendInputResult(delivered: true)
    if let wait = req.wait {
      let outcome = await waitForCompletion(paneID: req.paneID, wait: wait, sink: sink)
      let output =
        req.capture == true
        ? Self.capturedOutput(before: before ?? "", after: outcome.text, sent: req.text) : nil
      result = SendInputResult(
        delivered: true, completed: outcome.completed, waitedMillis: outcome.waitedMillis,
        busyObserved: outcome.busyObserved, output: output)
    }
    do {
      return .unary(try JSONValue.encoded(result))
    } catch {
      return .failed(.internal("encode sendInput result: \(error)"))
    }
  }

  private func inputFailure(for paneID: PaneID, sink: InputSink) -> RouterOutcome {
    if let reason = sink.inputRejectionReason(for: paneID) {
      return .failed(.conflict(reason: reason))
    }
    return .failed(.notFound(kind: "pane", id: paneID.description))
  }

  struct CompletionOutcome {
    let completed: Bool
    let waitedMillis: Int
    let busyObserved: Bool
    let text: String
  }

  private func waitForCompletion(
    paneID: PaneID, wait: SendWaitParams, sink: InputSink
  ) async -> CompletionOutcome {
    let timeout = max(wait.timeoutMillis, 1)
    let stable = max(wait.stableMillis ?? 500, 1)
    let grace = max(wait.graceMillis ?? 1500, 1)
    let interval = 100
    let start = clock.nowMillis()
    var busyObserved = false
    var lastText = sink.readText(paneID: paneID, extent: .screen) ?? ""
    var stableSince = start
    while true {
      let now = clock.nowMillis()
      let busy = paneIsBusy(paneID)
      if busy { busyObserved = true }
      let text = sink.readText(paneID: paneID, extent: .screen) ?? ""
      if text != lastText {
        lastText = text
        stableSince = now
      }
      let elapsed = now - start
      let quiet = now - stableSince
      if !busy, quiet >= stable, busyObserved || elapsed >= grace {
        return CompletionOutcome(completed: true, waitedMillis: elapsed, busyObserved: busyObserved, text: text)
      }
      if elapsed >= timeout {
        return CompletionOutcome(completed: false, waitedMillis: elapsed, busyObserved: busyObserved, text: text)
      }
      do {
        try await clock.sleep(millis: min(interval, timeout - elapsed))
      } catch {
        return CompletionOutcome(completed: false, waitedMillis: elapsed, busyObserved: busyObserved, text: text)
      }
    }
  }

  /// The screen lines that appeared after the send: everything past the
  /// longest common line prefix of the before / after screens, minus the
  /// echoed command line, the redrawn prompt (a last line equal to the
  /// screen's last line before the send), and trailing blank rows. A
  /// command that clears the screen leaves no common prefix, so the whole
  /// screen comes back. Best effort: the terminal exposes rendered text,
  /// not command boundaries.
  static func capturedOutput(before: String, after: String, sent: String) -> String {
    let beforeLines = before.split(separator: "\n", omittingEmptySubsequences: false)
    var afterLines = after.split(separator: "\n", omittingEmptySubsequences: false)
    while let last = afterLines.last, last.trimmingCharacters(in: .whitespaces).isEmpty {
      afterLines.removeLast()
    }
    let promptLine = beforeLines.last(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty })
    if let promptLine, afterLines.count > 1, afterLines.last == promptLine {
      afterLines.removeLast()
    }
    var common = 0
    while common < beforeLines.count, common < afterLines.count, beforeLines[common] == afterLines[common] {
      common += 1
    }
    afterLines.removeFirst(common)
    let firstSentLine =
      sent.split(separator: "\n").first.map(String.init)?
      .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    if let first = afterLines.first, !firstSentLine.isEmpty, first.contains(firstSentLine) {
      afterLines.removeFirst()
    }
    while let last = afterLines.last, last.trimmingCharacters(in: .whitespaces).isEmpty {
      afterLines.removeLast()
    }
    return afterLines.joined(separator: "\n")
  }

  public struct SendKeyParams: Codable, Sendable {
    public let paneID: PaneID
    public let key: IPC.TerminalNamedKey
  }
  public func sendKey(_ params: JSONValue) async -> RouterOutcome {
    await Task.yield()
    guard let sink else {
      return .failed(
        .unsupported(reason: "no GhosttyRuntime bound — terminal.sendKey requires the app with panes live"))
    }
    let req: SendKeyParams
    do {
      req = try params.decoded(as: SendKeyParams.self)
    } catch {
      return .failed(.invalidParams(message: "sendKey requires {paneID, key}", path: nil))
    }
    let ok = sink.sendKey(paneID: req.paneID, key: req.key)
    if !ok { return inputFailure(for: req.paneID, sink: sink) }
    return .unary(.object(["delivered": .bool(true)]))
  }

  public struct SendRawBytesParams: Codable, Sendable {
    public let paneID: PaneID
    /// Hex-encoded bytes, e.g. "1b5b41" for ESC [ A (up arrow CSI).
    /// Whitespace and an optional "0x" prefix are tolerated by the decoder.
    public let hex: String
  }
  public func sendRawBytes(_ params: JSONValue) async -> RouterOutcome {
    await Task.yield()
    guard let sink else {
      return .failed(
        .unsupported(reason: "no GhosttyRuntime bound — terminal.sendRawBytes requires the app with panes live"))
    }
    let req: SendRawBytesParams
    do {
      req = try params.decoded(as: SendRawBytesParams.self)
    } catch {
      return .failed(.invalidParams(message: "sendRawBytes requires {paneID, hex}", path: nil))
    }
    guard let bytes = Self.decodeHex(req.hex) else {
      return .failed(.invalidParams(message: "hex must be an even-length hex string", path: ["hex"]))
    }
    let ok = sink.sendRawBytes(paneID: req.paneID, bytes: bytes)
    if !ok { return inputFailure(for: req.paneID, sink: sink) }
    return .unary(
      .object([
        "delivered": .bool(true),
        "bytes": .int(Int64(bytes.count)),
      ]))
  }

  /// Whitespace separates tokens and each token may carry its own `0x`,
  /// so `"0x15 0x0d"` and `"150d"` decode alike.
  static func decodeHex(_ raw: String) -> [UInt8]? {
    let str = raw.split(whereSeparator: \.isWhitespace)
      .map { token -> Substring in
        token.hasPrefix("0x") || token.hasPrefix("0X") ? token.dropFirst(2) : token
      }
      .joined()
    guard !str.isEmpty, str.count.isMultiple(of: 2) else { return nil }
    var bytes: [UInt8] = []
    bytes.reserveCapacity(str.count / 2)
    var index = str.startIndex
    while index < str.endIndex {
      let next = str.index(index, offsetBy: 2)
      guard let byte = UInt8(str[index..<next], radix: 16) else { return nil }
      bytes.append(byte)
      index = next
    }
    return bytes
  }

  public struct BroadcastParams: Codable, Sendable {
    public let scope: IPC.BroadcastScope
    public let text: String
  }
  public func broadcastInput(_ params: JSONValue) async -> RouterOutcome {
    await Task.yield()
    guard let sink else {
      return .failed(
        .unsupported(reason: "no GhosttyRuntime bound — terminal.broadcastInput requires the app with panes live"))
    }
    let req: BroadcastParams
    do {
      req = try params.decoded(as: BroadcastParams.self)
    } catch {
      return .failed(.invalidParams(message: "broadcastInput requires {scope, text}", path: nil))
    }
    let count = sink.fanOut(scope: req.scope, text: req.text, catalog: catalog())
    return .unary(.object(["delivered": .int(Int64(count))]))
  }

  /// Tuning for the optional wait-stable poll: read the pane repeatedly
  /// until its rendered text holds steady for `stableMillis`, capped at
  /// `timeoutMillis`, sampling every `intervalMillis`.
  public struct WaitStableParams: Codable, Sendable {
    public let stableMillis: Int
    public let intervalMillis: Int
    public let timeoutMillis: Int
  }
  public struct ReadTextParams: Codable, Sendable {
    public let paneID: PaneID
    public let extent: ReadExtent?
    /// When present, poll until stable instead of reading once.
    public let waitStable: WaitStableParams?
  }
  /// The stability fields are populated only for wait-stable reads; a plain
  /// read encodes just `text` (the optionals are omitted).
  public struct ReadTextResult: Codable, Sendable {
    public let text: String
    public let stabilized: Bool?
    public let waitedMillis: Int?
    public let samples: Int?

    public init(text: String, stabilized: Bool? = nil, waitedMillis: Int? = nil, samples: Int? = nil) {
      self.text = text
      self.stabilized = stabilized
      self.waitedMillis = waitedMillis
      self.samples = samples
    }
  }
  public func readText(_ params: JSONValue) async -> RouterOutcome {
    await Task.yield()
    guard let sink else {
      return .failed(
        .unsupported(reason: "no GhosttyRuntime bound — terminal.readText requires the app with panes live"))
    }
    let req: ReadTextParams
    do {
      req = try params.decoded(as: ReadTextParams.self)
    } catch {
      return .failed(.invalidParams(message: "readText requires {paneID}", path: nil))
    }
    let extent = req.extent ?? .viewport
    let result: ReadTextResult
    if let ws = req.waitStable {
      let waiter = TerminalStabilityWaiter(
        clock: clock,
        stableMillis: ws.stableMillis,
        intervalMillis: ws.intervalMillis,
        timeoutMillis: ws.timeoutMillis,
        read: { [sink] in sink.readText(paneID: req.paneID, extent: extent) }
      )
      guard let outcome = await waiter.run() else {
        return .failed(.notFound(kind: "pane", id: req.paneID.description))
      }
      result = ReadTextResult(
        text: outcome.text,
        stabilized: outcome.stabilized,
        waitedMillis: outcome.waitedMillis,
        samples: outcome.samples
      )
    } else {
      guard let text = sink.readText(paneID: req.paneID, extent: extent) else {
        return .failed(.notFound(kind: "pane", id: req.paneID.description))
      }
      result = ReadTextResult(text: text)
    }
    do {
      return .unary(try JSONValue.encoded(result))
    } catch {
      return .failed(.internal("encode readText result: \(error)"))
    }
  }

  public struct ResetPaneParams: Codable, Sendable {
    public let paneID: PaneID
  }
  public func resetPane(_ params: JSONValue) async -> RouterOutcome {
    await Task.yield()
    guard let sink else {
      return .failed(
        .unsupported(reason: "no GhosttyRuntime bound — terminal.resetPane requires the app with panes live"))
    }
    let req: ResetPaneParams
    do {
      req = try params.decoded(as: ResetPaneParams.self)
    } catch {
      return .failed(.invalidParams(message: "resetPane requires {paneID}", path: nil))
    }
    let ok = sink.resetPane(paneID: req.paneID)
    if !ok {
      return .failed(.notFound(kind: "pane", id: req.paneID.description))
    }
    return .unary(.object(["reset": .bool(true)]))
  }
}

extension TerminalHandlers.InputSink {
  public func inputRejectionReason(for paneID: PaneID) -> String? { nil }
}

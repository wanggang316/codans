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
    func fanOut(scope: IPC.BroadcastScope, text: String, catalog: Catalog) -> Int
    func readText(paneID: PaneID, extent: ReadExtent) -> String?
    func resetPane(paneID: PaneID) -> Bool
    /// Whether the pane has a surface laid out on the Mac — what key
    /// encoding needs.
    func hasLiveSurface(paneID: PaneID) -> Bool
    /// Deliver one `key`, `text` or `paste` event. Limits are already
    /// checked; `delay` and `unknown` never reach the sink.
    func sendInputEvent(paneID: PaneID, event: IPC.TerminalInputEvent) -> InputEventOutcome
  }

  public enum InputEventOutcome: Equatable, Sendable {
    case delivered
    /// Not delivered, for a `TerminalInputRejection.Reason`.
    case rejected(reason: String)
    /// The pane's surface is gone; the rest of the batch cannot land.
    case paneGone
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
  /// Attaches a surface to a detached pane (its daemon runs, no surface is
  /// bound: restored and not opened yet, or released by the idle reclaim)
  /// and returns whether it did. Pane verbs call it first, so a pane that
  /// `pane.describe` / `agent.listStates` report live is one they can reach.
  private let attachDetached: @MainActor (PaneID) async -> Bool
  /// The pane daemon's own terminal text (`pane.read`'s plain dump), or nil
  /// when it cannot be read. The daemon does not replay, so this is the
  /// source of truth while a new surface fills in.
  private let daemonScreen: @MainActor (PaneID) async -> String?
  private let logger = Logger(subsystem: "com.gumpw.codans.ipc", category: "terminal")

  public init(
    sink: InputSink?,
    catalog: @escaping @MainActor () -> Catalog,
    clock: StabilityClock = SystemStabilityClock(),
    paneIsBusy: @escaping @MainActor (PaneID) -> Bool = { _ in false },
    attachDetached: @escaping @MainActor (PaneID) async -> Bool = { _ in false },
    daemonScreen: @escaping @MainActor (PaneID) async -> String? = { _ in nil }
  ) {
    self.sink = sink
    self.catalog = catalog
    self.clock = clock
    self.paneIsBusy = paneIsBusy
    self.attachDetached = attachDetached
    self.daemonScreen = daemonScreen
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
    let attached = await attachIfDetached(req.paneID, sink: sink)
    // A surface attached by this call may still be replaying the daemon's
    // screen, so its text is no capture baseline: rows that land later would
    // read as the command's output. The daemon does not replay, so both ends
    // of the capture come from its dump, and only from it: falling back to
    // the surface, or mixing the two, would bring the replay back. When the
    // daemon cannot be read before the send, nothing is sent.
    var before: String?
    let captureFromDaemon = req.capture == true && attached
    if captureFromDaemon {
      guard let dump = await readDaemonScreen(req.paneID) else {
        return .failed(
          .internal("pane.send --capture: cannot read the pane daemon's screen; nothing was sent, retry"))
      }
      before = dump
    } else if req.capture == true {
      before = sink.readText(paneID: req.paneID, extent: .screen)
    }
    let ok = sink.sendInput(paneID: req.paneID, text: req.text)
    if !ok {
      return .failed(unreachable(req.paneID))
    }
    var result = SendInputResult(delivered: true)
    if let wait = req.wait {
      let outcome = await waitForCompletion(paneID: req.paneID, wait: wait, sink: sink)
      var after = outcome.text
      if captureFromDaemon {
        guard let dump = await readDaemonScreen(req.paneID) else {
          return .failed(
            .internal("pane.send --capture: the text was sent, but the pane daemon's screen could not be read to capture its output"))
        }
        after = dump
      }
      let output = req.capture == true
        ? Self.capturedOutput(before: before ?? "", after: after, sent: req.text) : nil
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
    _ = await attachIfDetached(req.paneID, sink: sink)
    let ok = sink.sendKey(paneID: req.paneID, key: req.key)
    if !ok {
      return .failed(unreachable(req.paneID))
    }
    return .unary(.object(["delivered": .bool(true)]))
  }

  /// `terminal.sendEvents` — an ordered batch of keys, typed text, pastes
  /// and delays for one pane. Events are applied in order; one that cannot
  /// be delivered is reported in `rejected` and the rest still run, so a
  /// newer client's unknown event never costs the keys around it.
  public func sendEvents(_ params: JSONValue) async -> RouterOutcome {
    await Task.yield()
    guard let sink else {
      return .failed(
        .unsupported(reason: "no GhosttyRuntime bound — terminal.sendEvents requires the app with panes live"))
    }
    let req: IPC.TerminalSendEventsRequest
    do {
      req = try params.decoded(as: IPC.TerminalSendEventsRequest.self)
    } catch {
      return .failed(.invalidParams(message: "sendEvents requires {paneID, events}: \(error)", path: nil))
    }
    guard req.events.count <= IPC.TerminalSendEventsRequest.maxEvents else {
      return .failed(
        .invalidParams(
          message: "at most \(IPC.TerminalSendEventsRequest.maxEvents) events per call", path: ["events"]))
    }
    guard catalog().pane(req.paneID) != nil else {
      return .failed(.notFound(kind: "pane", id: req.paneID.description))
    }
    guard sink.hasLiveSurface(paneID: req.paneID) else {
      return .failed(.unsupported(reason: "pane not open on the Mac"))
    }
    var delivered = 0
    var rejected: [IPC.TerminalInputRejection] = []
    var delayBudget = IPC.TerminalSendEventsRequest.maxTotalDelayMillis
    var paneGone = false
    for (index, event) in req.events.enumerated() {
      let outcome: InputEventOutcome =
        paneGone
        ? .paneGone
        : await apply(event, paneID: req.paneID, sink: sink, delayBudget: &delayBudget)
      switch outcome {
      case .delivered:
        delivered += 1
      case .rejected(let reason):
        rejected.append(IPC.TerminalInputRejection(index: index, reason: reason))
      case .paneGone:
        paneGone = true
        rejected.append(
          IPC.TerminalInputRejection(index: index, reason: IPC.TerminalInputRejection.Reason.paneGone))
      }
    }
    do {
      return .unary(try JSONValue.encoded(IPC.TerminalSendEventsResult(delivered: delivered, rejected: rejected)))
    } catch {
      return .failed(.internal("encode sendEvents result: \(error)"))
    }
  }

  /// One event of a `sendEvents` batch: limits first, then the sink. A
  /// cancelled delay means the caller is gone, so it ends the batch like a
  /// closed surface does.
  private func apply(
    _ event: IPC.TerminalInputEvent, paneID: PaneID, sink: InputSink, delayBudget: inout Int
  ) async -> InputEventOutcome {
    switch event {
    case .unknown:
      return .rejected(reason: IPC.TerminalInputRejection.Reason.unknownEvent)
    case .delay(let millis):
      guard (0...IPC.TerminalInputEvent.maxDelayMillis).contains(millis), millis <= delayBudget else {
        return .rejected(reason: IPC.TerminalInputRejection.Reason.outOfRange)
      }
      delayBudget -= millis
      do {
        try await clock.sleep(millis: millis)
        return .delivered
      } catch {
        return .paneGone
      }
    case .text(let text), .paste(let text):
      guard text.utf8.count <= IPC.TerminalInputEvent.maxTextBytes else {
        return .rejected(reason: IPC.TerminalInputRejection.Reason.tooLarge)
      }
      return sink.sendInputEvent(paneID: paneID, event: event)
    case .key(_, let text, _):
      // A key's text is typed like `text`, so it gets the same cap.
      if let text, text.utf8.count > IPC.TerminalInputEvent.maxTextBytes {
        return .rejected(reason: IPC.TerminalInputRejection.Reason.tooLarge)
      }
      return sink.sendInputEvent(paneID: paneID, event: event)
    }
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
    _ = await attachIfDetached(req.paneID, sink: sink)
    let ok = sink.sendRawBytes(paneID: req.paneID, bytes: bytes)
    if !ok {
      return .failed(unreachable(req.paneID))
    }
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
    _ = await attachIfDetached(req.paneID, sink: sink)
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
        return .failed(unreachable(req.paneID))
      }
      result = ReadTextResult(
        text: outcome.text,
        stabilized: outcome.stabilized,
        waitedMillis: outcome.waitedMillis,
        samples: outcome.samples
      )
    } else {
      guard let text = sink.readText(paneID: req.paneID, extent: extent) else {
        return .failed(unreachable(req.paneID))
      }
      result = ReadTextResult(text: text)
    }
    do {
      return .unary(try JSONValue.encoded(result))
    } catch {
      return .failed(.internal("encode readText result: \(error)"))
    }
  }

  /// Attaches a surface to a detached pane, then waits for the surface to
  /// show the daemon's screen, up to `replayWaitMillis`. A new surface
  /// starts blank and fills in as the daemon replays its screen and modes;
  /// input sent before the replay lands is encoded for the wrong modes (for
  /// example a TUI's keyboard protocol), and a read returns a partial screen.
  /// The wait is best effort: nothing depends on proof that it completed
  /// (`sendInput`'s capture reads the daemon instead). Returns whether this
  /// call attached the surface.
  func attachIfDetached(_ paneID: PaneID, sink: InputSink) async -> Bool {
    guard await attachDetached(paneID) else { return false }
    let start = clock.nowMillis()
    while clock.nowMillis() - start < Self.replayWaitMillis {
      guard let surface = sink.readText(paneID: paneID, extent: .screen) else { break }
      if let daemon = await daemonScreen(paneID), Self.replayCaughtUp(surface: surface, daemon: daemon) { break }
      do { try await clock.sleep(millis: 50) } catch { break }
    }
    return true
  }

  static let replayWaitMillis = 3000

  /// Reads the daemon's screen, retrying a failed read a few times: the
  /// capture of a just-attached pane depends on it.
  private func readDaemonScreen(_ paneID: PaneID) async -> String? {
    for attempt in 0..<Self.daemonReadAttempts {
      if let dump = await daemonScreen(paneID) { return dump }
      if attempt + 1 < Self.daemonReadAttempts {
        do { try await clock.sleep(millis: 100) } catch { return nil }
      }
    }
    return nil
  }

  static let daemonReadAttempts = 3

  /// Whether the surface shows the daemon's screen: the daemon's last
  /// non-blank rows (up to `replayCompareRows`) end the surface text too.
  /// Rows compare without trailing whitespace, the one difference between
  /// the daemon's plain dump and libghostty's rendered text.
  static func replayCaughtUp(surface: String, daemon: String) -> Bool {
    let expected = normalizedRows(daemon).suffix(replayCompareRows)
    let shown = normalizedRows(surface)
    return shown.count >= expected.count && shown.suffix(expected.count).elementsEqual(expected)
  }

  static let replayCompareRows = 20

  private static func normalizedRows(_ text: String) -> [Substring] {
    var rows = text.split(separator: "\n", omittingEmptySubsequences: false).map { row -> Substring in
      guard let last = row.lastIndex(where: { !$0.isWhitespace }) else { return row[row.startIndex..<row.startIndex] }
      return row[...last]
    }
    while rows.last?.isEmpty == true { rows.removeLast() }
    return rows
  }

  /// Why a terminal verb could not reach a pane: an id outside the catalog
  /// is `notFound`; a catalog pane whose terminal does not run (no daemon)
  /// is `PANE_NOT_LIVE`, so a script can tell it from a wrong id.
  private func unreachable(_ paneID: PaneID) -> IPCError {
    catalog().pane(paneID) == nil ? .notFound(kind: "pane", id: paneID.description) : .paneNotLive(paneID.description)
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
    _ = await attachIfDetached(req.paneID, sink: sink)
    let ok = sink.resetPane(paneID: req.paneID)
    if !ok {
      return .failed(unreachable(req.paneID))
    }
    return .unary(.object(["reset": .bool(true)]))
  }
}

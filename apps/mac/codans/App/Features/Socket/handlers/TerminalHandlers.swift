import Foundation
import CodansCore
import CodansIPC
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
  }

  public enum ReadExtent: String, Codable, Sendable {
    case viewport
    case screen
    case selection
  }

  private let sink: InputSink?
  private let catalog: @MainActor () -> Catalog
  /// Time source for `readText`'s wait-stable poll loop. Injectable so
  /// tests drive the loop with a virtual clock; production uses the real one.
  private let clock: StabilityClock
  private let logger = Logger(subsystem: "com.gumpw.codans.ipc", category: "terminal")

  public init(
    sink: InputSink?,
    catalog: @escaping @MainActor () -> Catalog,
    clock: StabilityClock = SystemStabilityClock()
  ) {
    self.sink = sink
    self.catalog = catalog
    self.clock = clock
  }

  public struct SendInputParams: Codable, Sendable {
    public let paneID: PaneID
    public let text: String
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
    let ok = sink.sendInput(paneID: req.paneID, text: req.text)
    if !ok {
      return .failed(.notFound(kind: "pane", id: req.paneID.description))
    }
    return .unary(.object(["delivered": .bool(true)]))
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
    if !ok {
      return .failed(.notFound(kind: "pane", id: req.paneID.description))
    }
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
    if !ok {
      return .failed(.notFound(kind: "pane", id: req.paneID.description))
    }
    return .unary(
      .object([
        "delivered": .bool(true),
        "bytes": .int(Int64(bytes.count)),
      ]))
  }

  static func decodeHex(_ raw: String) -> [UInt8]? {
    var cleaned = raw.unicodeScalars.filter { !$0.properties.isWhitespace }
      .map(Character.init)
    if cleaned.count >= 2, cleaned[0] == "0", cleaned[1] == "x" || cleaned[1] == "X" {
      cleaned.removeFirst(2)
    }
    let str = String(cleaned)
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

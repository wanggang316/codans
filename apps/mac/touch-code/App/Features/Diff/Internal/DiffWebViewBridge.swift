import Foundation

/// JSON codec for the Swift ↔ JavaScript bridge that fronts the vendored
/// YiTong renderer. Pure data — no WebKit imports — so the codec is unit
/// testable without spinning up a `WKWebView`.
///
/// The renderer's actual inbound vocabulary (`initialize`,
/// `renderDocument`, `updateConfiguration`, `teardown`) does not match the
/// design doc's `setOptions` / `render` shorthand; we honour the JS side
/// because the vendored bundle is the source of truth and we cannot patch
/// it (Apache-2.0 NOTICE-clean policy). See Decision Log D8 on the exec
/// plan.
enum DiffBridgeProtocol {
  static let version = 1
}

// MARK: - Outbound (host → web)

/// Type tags the JS side dispatches on inside `__yitongReceiveMessage`.
enum DiffOutboundType: String {
  case initialize
  case renderDocument
  case updateConfiguration
  case teardown
  case scrollToFile
}

struct DiffOutboundEnvelope<Payload: Encodable>: Encodable {
  let protocolVersion: Int
  let type: String
  let payload: Payload

  init(type: DiffOutboundType, payload: Payload) {
    self.protocolVersion = DiffBridgeProtocol.version
    self.type = type.rawValue
    self.payload = payload
  }
}

// Renderer-shaped configuration. The vendored JS (`Vu`) reads
// `diffStyle`, `diffIndicators`, `showsChangeBackgrounds`, etc. — the
// names diverge slightly from `DiffConfiguration`, so we do the
// translation here once.
private struct WireConfiguration: Encodable {
  let resolvedAppearance: String
  let diffStyle: String
  let diffIndicators: String
  let showsLineNumbers: Bool
  let showsChangeBackgrounds: Bool
  let wrapsLines: Bool
  let showsFileHeaders: Bool
  let inlineChangeStyle: String
  let allowsSelection: Bool
}

private struct WireFile: Encodable {
  let oldPath: String?
  let newPath: String?
  let oldContents: String
  let newContents: String
}

private struct WireDocument: Encodable {
  let identifier: String
  let title: String?
  let files: [WireFile]?
  let patch: String?
}

private struct WireRenderPayload: Encodable {
  let document: WireDocument
  let configuration: WireConfiguration
}

enum DiffWebViewBridge {
  static let encoder: JSONEncoder = {
    let e = JSONEncoder()
    // Sorted keys give us deterministic byte-output for byte-equal payloads.
    // The Coordinator's send-cache keys on the script string, so unstable
    // key ordering would defeat dedupe — see Decision Log D25 / D26.
    e.outputFormatting = [.withoutEscapingSlashes, .sortedKeys]
    return e
  }()

  static let decoder = JSONDecoder()

  static func encodeRender(
    _ document: DiffDocument,
    configuration: DiffConfiguration
  ) throws -> String {
    let payload = WireRenderPayload(
      document: makeDocument(document),
      configuration: makeConfiguration(configuration)
    )
    return try encodeEnvelope(type: .renderDocument, payload: payload)
  }

  static func encodeSetOptions(_ configuration: DiffConfiguration) throws -> String {
    try encodeEnvelope(type: .updateConfiguration, payload: makeConfiguration(configuration))
  }

  static func encodeTeardown() throws -> String {
    struct Empty: Encodable {}
    return try encodeEnvelope(type: .teardown, payload: Empty())
  }

  static func encodeScrollToFile(_ path: String) throws -> String {
    struct ScrollPayload: Encodable {
      let path: String
    }
    return try encodeEnvelope(type: .scrollToFile, payload: ScrollPayload(path: path))
  }

  // MARK: - Inbound (web → host)

  /// Decodes one event posted via `webkit.messageHandlers.yitongBridge`.
  /// A protocol-version mismatch surfaces as `.didFail(code:
  /// "protocol_mismatch", ...)` rather than throwing, so the host UI can
  /// render an error state instead of silently dropping the event.
  static func decodeEvent(_ rawJSON: String) throws -> DiffEvent {
    guard let data = rawJSON.data(using: .utf8) else {
      throw BridgeError.invalidUTF8
    }
    let envelope = try decoder.decode(InboundEnvelope.self, from: data)
    guard envelope.protocolVersion == DiffBridgeProtocol.version else {
      return .didFail(
        code: "protocol_mismatch",
        message: "Unsupported protocol version \(envelope.protocolVersion)"
      )
    }
    return try mapPayload(type: envelope.type, payload: envelope.payload)
  }

  // MARK: - Helpers

  private static func encodeEnvelope<P: Encodable>(
    type: DiffOutboundType,
    payload: P
  ) throws -> String {
    let envelope = DiffOutboundEnvelope(type: type, payload: payload)
    let data = try encoder.encode(envelope)
    guard let s = String(data: data, encoding: .utf8) else { throw BridgeError.invalidUTF8 }
    return s
  }

  private static func makeConfiguration(_ c: DiffConfiguration) -> WireConfiguration {
    .init(
      resolvedAppearance: c.appearance == .dark ? "dark" : "light",
      diffStyle: c.style.rawValue,
      diffIndicators: c.indicators.rawValue,
      showsLineNumbers: c.showsLineNumbers,
      showsChangeBackgrounds: c.showsChangeBackgrounds,
      wrapsLines: c.wrapsLines,
      showsFileHeaders: c.showsFileHeaders,
      inlineChangeStyle: c.inlineChangeStyle.rawValue,
      allowsSelection: c.allowsSelection
    )
  }

  private static func makeDocument(_ doc: DiffDocument) -> WireDocument {
    // Deterministic identifier so re-encoding the same `DiffDocument`
    // yields byte-identical JSON — the Coordinator's send-cache uses
    // string equality to suppress duplicate `renderDocument` envelopes
    // on SwiftUI re-evaluations. Falling back to a UUID per-call would
    // defeat that dedupe and re-tokenise on every parent re-render.
    let identifier =
      doc.title
      ?? "doc-\(doc.files.map { $0.id }.joined(separator: ","))"
    let files: [WireFile]? =
      doc.files.isEmpty
      ? nil
      : doc.files.map {
        .init(oldPath: $0.oldPath, newPath: $0.newPath, oldContents: $0.oldContents, newContents: $0.newContents)
      }
    return WireDocument(
      identifier: identifier,
      title: doc.title,
      files: files,
      patch: doc.fallbackPatch
    )
  }

  private static func mapPayload(type: String, payload: AnyJSON) throws -> DiffEvent {
    switch type {
    case "ready":
      return .didFinishInitialLoad
    case "renderStateChanged":
      return mapRenderState(payload)
    case "lineActivated":
      let fileIndex = payload.dict?["fileIndex"]?.intValue ?? 0
      let number = payload.dict?["number"]?.intValue ?? 0
      return .didClickLine(fileIndex: fileIndex, lineNumber: number)
    case "selectionChanged":
      return .didChangeSelection(parseSelection(payload.dict?["selection"]))
    default:
      return .didFail(code: "unknown_event", message: "Unhandled event type: \(type)")
    }
  }

  private static func mapRenderState(_ payload: AnyJSON) -> DiffEvent {
    let dict = payload.dict ?? [:]
    let state = dict["state"]?.stringValue ?? ""
    switch state {
    case "rendered":
      let count = dict["summary"]?.dict?["fileCount"]?.intValue ?? 0
      return .didRender(fileCount: count)
    case "failed":
      let err = dict["error"]?.dict ?? [:]
      return .didFail(
        code: err["code"]?.stringValue ?? "render_failed",
        message: err["message"]?.stringValue ?? "Renderer reported a failure"
      )
    default:
      // "loading" is informational; surface as fileCount == 0 render in
      // progress would be misleading. Fold into didFail with a benign
      // code so we don't lose the signal entirely.
      return .didFail(code: "render_state", message: state)
    }
  }

  private static func parseSelection(_ value: AnyJSON?) -> SelectionRange? {
    guard let dict = value?.dict else { return nil }
    let fileIndex = dict["fileIndex"]?.intValue ?? 0
    let start = dict["start"]?.dict
    let end = dict["end"]?.dict
    let startN = start?["number"]?.intValue ?? 0
    let endN = end?["number"]?.intValue ?? startN
    let startSide = start?["side"]?.stringValue ?? "unified"
    let endSide = end?["side"]?.stringValue ?? startSide
    let side: SelectionSide
    if startSide == endSide {
      side = mapSide(startSide)
    } else {
      side = .both
    }
    return SelectionRange(fileIndex: fileIndex, start: startN, end: endN, side: side)
  }

  private static func mapSide(_ raw: String) -> SelectionSide {
    switch raw {
    case "old": return .deletions
    case "new": return .additions
    default: return .both
    }
  }

  enum BridgeError: Error {
    case invalidUTF8
  }
}

// MARK: - Inbound envelope + heterogeneous JSON

struct InboundEnvelope: Decodable {
  let protocolVersion: Int
  let id: String?
  let type: String
  let payload: AnyJSON
}

/// Minimal heterogeneous JSON container. Sufficient for inbound payload
/// inspection without committing to per-event Decodable types — payload
/// shapes evolve more often than the envelope itself.
indirect enum AnyJSON: Decodable, Sendable {
  case string(String)
  case int(Int)
  case double(Double)
  case bool(Bool)
  case array([AnyJSON])
  case object([String: AnyJSON])
  case null

  init(from decoder: Decoder) throws {
    let c = try decoder.singleValueContainer()
    if c.decodeNil() {
      self = .null
      return
    }
    if let b = try? c.decode(Bool.self) {
      self = .bool(b)
      return
    }
    if let i = try? c.decode(Int.self) {
      self = .int(i)
      return
    }
    if let d = try? c.decode(Double.self) {
      self = .double(d)
      return
    }
    if let s = try? c.decode(String.self) {
      self = .string(s)
      return
    }
    if let a = try? c.decode([AnyJSON].self) {
      self = .array(a)
      return
    }
    if let o = try? c.decode([String: AnyJSON].self) {
      self = .object(o)
      return
    }
    throw DecodingError.dataCorruptedError(
      in: c, debugDescription: "Unrecognized JSON value")
  }

  var stringValue: String? { if case .string(let s) = self { return s } else { return nil } }
  var intValue: Int? {
    switch self {
    case .int(let i): return i
    case .double(let d): return Int(d)
    default: return nil
    }
  }
  var dict: [String: AnyJSON]? { if case .object(let o) = self { return o } else { return nil } }
}

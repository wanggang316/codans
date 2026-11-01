import CodansCore
import Foundation

/// One terminal signal found in a detached pane's PTY output. These are the
/// OSC sequences a live surface turns into engine events; a pane without a
/// surface gets them from its passive zmx watcher instead.
nonisolated enum DetachedPaneSignal: Equatable, Sendable {
  /// OSC 0 / OSC 2.
  case title(String)
  /// OSC 9 (iTerm2 form). Text is untrusted program output.
  case desktopNotification(title: String, body: String)
  /// OSC 7501 report. Support queries (`?`) are not signals: only the
  /// attached terminal (or the daemon) answers them.
  case programStatus(ProgramStatusReport)
}

/// Incremental OSC scanner over raw PTY output. Sequences can split across
/// `.Output` frames, so the scanner keeps its state between `scan` calls.
///
/// It reads OSC strings only (`ESC ]` … `BEL` or `ESC \`), and ignores every
/// other byte. It does not track DCS / APC strings: an `ESC ]` inside one is
/// rare, and the parsers below reject bodies they do not recognise.
nonisolated struct ZmxOutputScanner: Sendable {
  /// Longest OSC body kept. OSC 7501 caps a whole sequence at 4096 bytes;
  /// longer bodies (OSC 52 clipboard data, for example) are skipped.
  static let maxBodyBytes = 4096

  private enum State: Sendable {
    case ground
    case escape
    case body
    case bodyEscape
  }

  private var state: State = .ground
  private var body: [UInt8] = []
  private var overflowed = false

  init() {}

  /// Scan `bytes` and return the signals they complete, in order.
  mutating func scan(_ bytes: Data) -> [DetachedPaneSignal] {
    var signals: [DetachedPaneSignal] = []
    for byte in bytes {
      if let signal = next(byte) { signals.append(signal) }
    }
    return signals
  }

  private mutating func next(_ byte: UInt8) -> DetachedPaneSignal? {
    switch state {
    case .ground:
      if byte == 0x1B { state = .escape }
    case .escape:
      if byte == 0x5D {
        startBody()
      } else if byte != 0x1B {
        state = .ground
      }
    case .body:
      switch byte {
      case 0x07:
        return finishBody()
      case 0x1B:
        state = .bodyEscape
      case 0x18, 0x1A:
        // CAN / SUB cancel the string.
        state = .ground
      default:
        append(byte)
      }
    case .bodyEscape:
      if byte == 0x5C { return finishBody() }
      // Any other ESC sequence ends the string without dispatching it.
      if byte == 0x5D {
        startBody()
      } else {
        state = byte == 0x1B ? .escape : .ground
      }
    }
    return nil
  }

  private mutating func startBody() {
    state = .body
    body.removeAll(keepingCapacity: true)
    overflowed = false
  }

  private mutating func append(_ byte: UInt8) {
    guard !overflowed else { return }
    if body.count >= Self.maxBodyBytes {
      overflowed = true
      body.removeAll(keepingCapacity: true)
      return
    }
    body.append(byte)
  }

  private mutating func finishBody() -> DetachedPaneSignal? {
    state = .ground
    guard !overflowed else { return nil }
    return Self.parse(body: body)
  }

  // MARK: - OSC bodies

  /// Parse one OSC body (the bytes between `ESC ]` and the terminator).
  static func parse(body: [UInt8]) -> DetachedPaneSignal? {
    guard let semicolon = body.firstIndex(of: 0x3B) else { return nil }
    let command = body[..<semicolon]
    let payload = Array(body[(semicolon + 1)...])
    switch String(decoding: command, as: UTF8.self) {
    case "0", "2":
      guard let title = String(bytes: payload, encoding: .utf8) else { return nil }
      return .title(title)
    case "9":
      guard !isConEmuExtension(payload),
        let text = String(bytes: payload, encoding: .utf8)
      else { return nil }
      return .desktopNotification(title: "", body: text)
    case "7501":
      return ProgramStatusParser.parse(body: payload).map(DetachedPaneSignal.programStatus)
    default:
      return nil
    }
  }

  /// ConEmu reuses OSC 9 for numbered extensions (`9;4;…` is progress).
  /// Mirrors the prefix checks in libghostty's `osc9.zig`: a body that
  /// matches one is an extension, every other body is a notification.
  static func isConEmuExtension(_ payload: [UInt8]) -> Bool {
    func byte(_ index: Int) -> UInt8? { index < payload.count ? payload[index] : nil }
    let semicolon: UInt8 = 0x3B
    switch byte(0) {
    case 0x35:  // 5: wait for input
      return true
    case 0x31:  // 1;  10  10;0-3  11;  12
      switch byte(1) {
      case semicolon: return true
      case 0x30:
        if payload.count == 2 { return true }
        return payload.count >= 4 && byte(2) == semicolon && (0x30...0x33).contains(payload[3])
      case 0x31: return byte(2) == semicolon
      case 0x32: return true
      default: return false
      }
    case 0x34:  // 4;0-4: progress
      return byte(1) == semicolon && byte(2).map { (0x30...0x34).contains($0) } == true
    case 0x32, 0x33, 0x36, 0x37, 0x38, 0x39:
      return byte(1) == semicolon
    default:
      return false
    }
  }
}

/// Swift port of libghostty's OSC 7501 report validation
/// (`ThirdParty/ghostty/src/terminal/osc/parsers/program_status.zig`). A
/// live surface gets reports already validated by libghostty; a passive
/// watcher reads raw bytes, so it applies the same rules before a report
/// reaches the engine.
nonisolated enum ProgramStatusParser {
  static let maxBodyBytes = 4096 - "\u{1B}]7501;".utf8.count - "\u{1B}\\".utf8.count
  static let maxKeyBytes = 16
  static let maxMsgEncodedBytes = 2732
  static let maxMsgBytes = 2048
  static let maxTitleEncodedBytes = 256
  static let maxTitleBytes = 192
  static let maxAppBytes = 32
  static let maxIDBytes = 128
  static let maxIDSegmentBytes = 32
  static let maxIDDepth = 8

  private static let nameBytes = Set(
    "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789_.+-".utf8)
  private static let valueBytes = nameBytes.union(",/=".utf8)

  /// Parse a report body (everything after `7501;`). Nil for a support
  /// query and for a report the specification says to discard.
  static func parse(body: [UInt8]) -> ProgramStatusReport? {
    guard body.count <= maxBodyBytes, body != [0x3F] else { return nil }
    let data = String(decoding: body, as: UTF8.self)
    let fields = data.split(separator: ":", omittingEmptySubsequences: false).map(String.init)

    for field in fields {
      guard let eq = field.firstIndex(of: "=") else { continue }
      if trim(field[..<eq]).utf8.count > maxKeyBytes { return nil }
    }
    for id in values("id", in: fields) where !isValidID(id) { return nil }
    for (key, limit) in [("app", maxAppBytes), ("title", maxTitleEncodedBytes), ("msg", maxMsgEncodedBytes)] {
      if values(key, in: fields).contains(where: { $0.utf8.count > limit }) { return nil }
    }

    var title: String?
    if let encoded = values("title", in: fields).last {
      guard let text = decodeText(encoded), text.utf8.count <= maxTitleBytes else { return nil }
      title = text
    }
    var message: String?
    if let encoded = values("msg", in: fields).last {
      guard let text = decodeText(encoded) else { return nil }
      message = text
    }
    guard let stateRaw = values("state", in: fields).last,
      let state = ProgramStatusState(rawValue: stateRaw)
    else { return nil }

    let app = values("app", in: fields).last.flatMap { isName($0) ? $0 : nil }
    let kind =
      state == .blocked
      ? values("kind", in: fields).last.flatMap(ProgramStatusKind.init(rawValue:)) : nil
    let progress: Int? =
      switch state {
      case .working, .blocked: values("progress", in: fields).last.flatMap(parseProgress)
      default: nil
      }
    return ProgramStatusReport(
      state: state,
      kind: kind,
      progress: progress,
      id: values("id", in: fields).last ?? "",
      app: app,
      title: title.flatMap { $0.isEmpty ? nil : $0 },
      message: message.flatMap { $0.isEmpty ? nil : $0 }
    )
  }

  /// Values of `key`, in order. Skips fields without `=` and values with
  /// bytes outside the value alphabet, like libghostty's `ValueIterator`.
  private static func values(_ key: String, in fields: [String]) -> [String] {
    fields.compactMap { field in
      guard let eq = field.firstIndex(of: "="), trim(field[..<eq]) == key else { return nil }
      let value = trim(field[field.index(after: eq)...])
      return value.utf8.allSatisfy { valueBytes.contains($0) } ? value : nil
    }
  }

  private static func trim(_ text: Substring) -> String {
    text.trimmingCharacters(in: .whitespaces)
  }

  private static func isName(_ text: String) -> Bool {
    !text.isEmpty && text.utf8.allSatisfy { nameBytes.contains($0) }
  }

  private static func isValidID(_ id: String) -> Bool {
    guard id.utf8.count <= maxIDBytes else { return false }
    let segments = id.split(separator: "/", omittingEmptySubsequences: false)
    guard segments.count <= maxIDDepth else { return false }
    return segments.allSatisfy { $0.utf8.count <= maxIDSegmentBytes && isName(String($0)) }
  }

  private static func parseProgress(_ value: String) -> Int? {
    guard !value.isEmpty else { return nil }
    var number = 0
    for byte in value.utf8 {
      guard (0x30...0x39).contains(byte) else { return nil }
      number = number * 10 + Int(byte - 0x30)
      if number > 100 { return nil }
    }
    return number
  }

  /// Base64 (padding optional) that decodes to UTF-8 without control
  /// characters, as libghostty's `isSafeUtf8` requires.
  private static func decodeText(_ encoded: String) -> String? {
    var padded = encoded
    if !padded.hasSuffix("=") {
      let remainder = padded.utf8.count % 4
      guard remainder != 1 else { return nil }
      if remainder > 0 { padded += String(repeating: "=", count: 4 - remainder) }
    }
    guard let decoded = Data(base64Encoded: padded), decoded.count <= maxMsgBytes,
      let text = String(data: decoded, encoding: .utf8)
    else { return nil }
    let hasControl = text.unicodeScalars.contains {
      $0.value < 0x20 || $0.value == 0x7F || (0x80...0x9F).contains($0.value)
    }
    return hasControl ? nil : text
  }
}

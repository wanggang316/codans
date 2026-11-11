import Foundation

/// Splits a byte stream into lines for `CommandRunner.runStream`. It splits
/// on bytes and decodes each complete line, so a multi-byte character that
/// two reads cut in half still decodes.
nonisolated final class LineSplitter: @unchecked Sendable {
  private let splitOnCarriageReturn: Bool
  private let lock = NSLock()
  // Guarded by `lock`.
  private var pending = Data()
  private var lastLine = ""

  init(splitOnCarriageReturn: Bool) {
    self.splitOnCarriageReturn = splitOnCarriageReturn
  }

  /// The last non-empty line so far, trimmed.
  var lastNonEmpty: String {
    lock.withLock { lastLine }
  }

  /// Appends `chunk` and returns the lines it completed.
  func consume(_ chunk: Data) -> [String] {
    lock.withLock {
      pending.append(chunk)
      var lines: [String] = []
      var start = pending.startIndex
      for index in pending.indices where isTerminator(pending[index]) {
        lines.append(String(bytes: pending[start..<index], encoding: .utf8) ?? "")
        start = pending.index(after: index)
      }
      pending.removeSubrange(pending.startIndex..<start)
      note(lines)
      return lines
    }
  }

  /// Returns the trailing bytes that did not end in a line terminator as a
  /// last line, if any.
  func flush() -> [String] {
    lock.withLock {
      guard !pending.isEmpty else { return [] }
      let line = String(bytes: pending, encoding: .utf8) ?? ""
      pending.removeAll()
      note([line])
      return [line]
    }
  }

  private func isTerminator(_ byte: UInt8) -> Bool {
    byte == UInt8(ascii: "\n") || (splitOnCarriageReturn && byte == UInt8(ascii: "\r"))
  }

  private func note(_ lines: [String]) {
    for line in lines {
      let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
      if !trimmed.isEmpty { lastLine = trimmed }
    }
  }
}

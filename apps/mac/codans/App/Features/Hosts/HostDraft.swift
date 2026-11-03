import CodansCore
import Foundation

/// The text fields of a Host form (Settings › Hosts editor and the
/// "New Host…" entry of Connect to Server). `record(id:)` turns them into a
/// `HostRecord` with the same validation as the Host list (ADR 0003).
nonisolated struct HostDraft: Equatable, Sendable {
  /// Longest text the Port field keeps. Five digits hold every valid port, so
  /// the text always parses as an `Int`.
  static let maxPortDigits = 5

  var address: String = ""
  var username: String = ""
  var port: String = ""
  var name: String = ""

  init(address: String = "", username: String = "", port: String = "", name: String = "") {
    self.address = address
    self.username = username
    self.port = port
    self.name = name
  }

  init(record: HostRecord) {
    self.init(
      address: record.address,
      username: record.username ?? "",
      port: record.port.map(String.init) ?? "",
      name: record.name ?? ""
    )
  }

  /// Keeps digits only, so the Port field cannot hold a non-numeric port.
  static func sanitizedPort(_ text: String) -> String {
    String(text.filter(\.isNumber).prefix(maxPortDigits))
  }

  /// The validated record for these fields. Throws `HostRecordError` for an
  /// empty Host field or a port outside 1...65535.
  func record(id: HostID = HostID()) throws(HostRecordError) -> HostRecord {
    let portText = port.trimmingCharacters(in: .whitespacesAndNewlines)
    let portNumber: Int?
    if portText.isEmpty {
      portNumber = nil
    } else if let parsed = Int(portText) {
      portNumber = parsed
    } else {
      throw .invalidPort(0)
    }
    return try HostRecord(
      id: id, address: address, username: username, port: portNumber, name: name
    ).validated()
  }
}

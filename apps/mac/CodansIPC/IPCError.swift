import Foundation

/// Errors carried in `IPC.Response.error`. The wire form is
/// `{ "code": String, "message": String, "path": [String]? }` — enum
/// discriminator is the `code` field.
public enum IPCError: Error, Equatable, Sendable {
  case unknownMethod(String)
  case invalidParams(message: String, path: [String]?)
  case notFound(kind: String, id: String)
  case conflict(reason: String)
  case unsupported(reason: String)
  case `internal`(String)
  case overloaded
  case versionMismatch(client: String, server: String)
  case invalidFrame(reason: String)

  public var code: String {
    switch self {
    case .unknownMethod: return "unknownMethod"
    case .invalidParams: return "invalidParams"
    case .notFound: return "notFound"
    case .conflict: return "conflict"
    case .unsupported: return "unsupported"
    case .internal: return "internal"
    case .overloaded: return "overloaded"
    case .versionMismatch: return "versionMismatch"
    case .invalidFrame: return "invalidFrame"
    }
  }

  /// The raw `message` payload written to the wire. For single-argument
  /// variants the argument IS this field; for structured variants (notFound,
  /// versionMismatch) auxiliary data is carried in dedicated keys and the
  /// message is a short human-oriented label.
  ///
  /// **Callers rendering to humans** (CLI `error:` lines, `os.Logger` on
  /// the app side) should prefer ``displayMessage`` — it formats the raw
  /// payload with helpful context (e.g. `"unknown method: foo.bar"` vs.
  /// the bare `"foo.bar"` `.message` returns for `.unknownMethod`).
  public var message: String {
    switch self {
    case .unknownMethod(let s): return s
    case .invalidParams(let m, _): return m
    case .notFound: return "not found"
    case .conflict(let r): return r
    case .unsupported(let r): return r
    case .internal(let s): return s
    case .overloaded: return "overloaded"
    case .versionMismatch: return "version mismatch"
    case .invalidFrame(let r): return r
    }
  }

  /// Human-formatted display string, suitable for `error:` CLI output.
  public var displayMessage: String {
    switch self {
    case .unknownMethod(let s): return "unknown method: \(s)"
    case .invalidParams(let m, _): return m
    case .notFound(let kind, let id): return "\(kind) not found: \(id)"
    case .conflict(let r): return r
    case .unsupported(let r): return r
    case .internal(let s): return s
    case .overloaded: return "server overloaded; retry with backoff"
    case .versionMismatch(let c, let s):
      return "client v\(c) incompatible with server v\(s)"
    case .invalidFrame(let r): return r
    }
  }
}

extension IPCError: Codable {
  private enum CodingKeys: String, CodingKey { case code, message, path, kind, id, client, server }

  public enum DecodingIssue: Error, Equatable {
    case unknownCode(String)
  }

  public init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    let code = try c.decode(String.self, forKey: .code)
    let message = try c.decodeIfPresent(String.self, forKey: .message) ?? ""
    switch code {
    case "unknownMethod":
      self = .unknownMethod(message)
    case "invalidParams":
      let path = try c.decodeIfPresent([String].self, forKey: .path)
      self = .invalidParams(message: message, path: path)
    case "notFound":
      let kind = try c.decodeIfPresent(String.self, forKey: .kind) ?? ""
      let id = try c.decodeIfPresent(String.self, forKey: .id) ?? ""
      self = .notFound(kind: kind, id: id)
    case "conflict":
      self = .conflict(reason: message)
    case "unsupported":
      self = .unsupported(reason: message)
    case "internal":
      self = .internal(message)
    case "overloaded":
      self = .overloaded
    case "versionMismatch":
      let client = try c.decodeIfPresent(String.self, forKey: .client) ?? ""
      let server = try c.decodeIfPresent(String.self, forKey: .server) ?? ""
      self = .versionMismatch(client: client, server: server)
    case "invalidFrame":
      self = .invalidFrame(reason: message)
    default:
      throw DecodingIssue.unknownCode(code)
    }
  }

  public func encode(to encoder: Encoder) throws {
    var c = encoder.container(keyedBy: CodingKeys.self)
    try c.encode(code, forKey: .code)
    try c.encode(message, forKey: .message)
    switch self {
    case .invalidParams(_, let path):
      try c.encodeIfPresent(path, forKey: .path)
    case .notFound(let kind, let id):
      try c.encode(kind, forKey: .kind)
      try c.encode(id, forKey: .id)
    case .versionMismatch(let client, let server):
      try c.encode(client, forKey: .client)
      try c.encode(server, forKey: .server)
    default:
      break
    }
  }
}

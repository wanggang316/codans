import Foundation

/// Dynamic JSON value used for request params and response results in the
/// wire envelope. Typed decoders live in the per-method callers: the router
/// receives an `IPC.Request` with `params: JSONValue`, re-encodes the
/// relevant subtree, and decodes into the method-specific param type.
public enum JSONValue: Equatable, Sendable, Hashable {
  case null
  case bool(Bool)
  case int(Int64)
  case double(Double)
  case string(String)
  case array([JSONValue])
  case object([String: JSONValue])
}

extension JSONValue: Codable {
  public init(from decoder: Decoder) throws {
    let c = try decoder.singleValueContainer()
    if c.decodeNil() {
      self = .null
    } else if let b = try? c.decode(Bool.self) {
      self = .bool(b)
    } else if let i = try? c.decode(Int64.self) {
      self = .int(i)
    } else if let d = try? c.decode(Double.self) {
      self = .double(d)
    } else if let s = try? c.decode(String.self) {
      self = .string(s)
    } else if let a = try? c.decode([JSONValue].self) {
      self = .array(a)
    } else if let o = try? c.decode([String: JSONValue].self) {
      self = .object(o)
    } else {
      throw DecodingError.dataCorruptedError(
        in: c, debugDescription: "Unrecognised JSON value"
      )
    }
  }

  public func encode(to encoder: Encoder) throws {
    var c = encoder.singleValueContainer()
    switch self {
    case .null: try c.encodeNil()
    case .bool(let b): try c.encode(b)
    case .int(let i): try c.encode(i)
    case .double(let d): try c.encode(d)
    case .string(let s): try c.encode(s)
    case .array(let a): try c.encode(a)
    case .object(let o): try c.encode(o)
    }
  }
}

extension JSONValue {
  /// Decode this value as the given Codable type by round-tripping through
  /// JSON bytes. Convenient for router code that receives a `JSONValue` and
  /// wants a typed `params` struct.
  public func decoded<T: Decodable>(
    as type: T.Type,
    decoder: JSONDecoder = JSONDecoder()
  ) throws -> T {
    let data = try JSONEncoder().encode(self)
    return try decoder.decode(type, from: data)
  }

  /// Build a `JSONValue` by round-tripping through JSON bytes. Convenient for
  /// callers that have a typed `params` struct and want to stuff it into an
  /// `IPC.Request` envelope.
  public static func encoded<T: Encodable>(
    _ value: T,
    encoder: JSONEncoder = JSONEncoder()
  ) throws -> JSONValue {
    let data = try encoder.encode(value)
    return try JSONDecoder().decode(JSONValue.self, from: data)
  }
}

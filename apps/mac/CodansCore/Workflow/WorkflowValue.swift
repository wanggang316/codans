import Foundation

/// A JSON-shaped value as a workflow sees it: inputs, state, step outputs,
/// and every name an expression can dereference. Integers only — the
/// expression language has no floating point, so a YAML `1.5` is rejected at
/// parse time rather than silently truncated here.
public nonisolated indirect enum WorkflowValue: Equatable, Sendable, Hashable {
  case null
  case bool(Bool)
  case int(Int)
  case string(String)
  case array([WorkflowValue])
  case object([String: WorkflowValue])

  /// Human-readable type name for diagnostics (`expected boolean, got string`).
  public var typeName: String {
    switch self {
    case .null: return "null"
    case .bool: return "boolean"
    case .int: return "number"
    case .string: return "string"
    case .array: return "array"
    case .object: return "object"
    }
  }

  public var isNull: Bool {
    if case .null = self { return true }
    return false
  }

  public var boolValue: Bool? {
    if case .bool(let value) = self { return value }
    return nil
  }

  public var intValue: Int? {
    if case .int(let value) = self { return value }
    return nil
  }

  public var stringValue: String? {
    if case .string(let value) = self { return value }
    return nil
  }

  public var arrayValue: [WorkflowValue]? {
    if case .array(let value) = self { return value }
    return nil
  }

  public var objectValue: [String: WorkflowValue]? {
    if case .object(let value) = self { return value }
    return nil
  }

  /// Member lookup on objects; `nil` for any other shape or a missing key.
  public subscript(key: String) -> WorkflowValue? {
    objectValue?[key]
  }

  /// Scalar rendering for text interpolation. Arrays and objects have no
  /// text form; the renderer reports them as a type error instead.
  public var interpolatedText: String? {
    switch self {
    case .null: return ""
    case .bool(let value): return value ? "true" : "false"
    case .int(let value): return String(value)
    case .string(let value): return value
    case .array, .object: return nil
    }
  }
}

extension WorkflowValue: Codable {
  public init(from decoder: Decoder) throws {
    let container = try decoder.singleValueContainer()
    if container.decodeNil() {
      self = .null
    } else if let value = try? container.decode(Bool.self) {
      self = .bool(value)
    } else if let value = try? container.decode(Int.self) {
      self = .int(value)
    } else if let value = try? container.decode(String.self) {
      self = .string(value)
    } else if let value = try? container.decode([WorkflowValue].self) {
      self = .array(value)
    } else if let value = try? container.decode([String: WorkflowValue].self) {
      self = .object(value)
    } else {
      throw DecodingError.dataCorruptedError(
        in: container, debugDescription: "unsupported workflow value")
    }
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.singleValueContainer()
    switch self {
    case .null: try container.encodeNil()
    case .bool(let value): try container.encode(value)
    case .int(let value): try container.encode(value)
    case .string(let value): try container.encode(value)
    case .array(let value): try container.encode(value)
    case .object(let value): try container.encode(value)
    }
  }
}

extension WorkflowValue: ExpressibleByStringLiteral, ExpressibleByIntegerLiteral,
  ExpressibleByBooleanLiteral, ExpressibleByNilLiteral
{
  public init(stringLiteral value: String) { self = .string(value) }
  public init(integerLiteral value: Int) { self = .int(value) }
  public init(booleanLiteral value: Bool) { self = .bool(value) }
  public init(nilLiteral: ()) { self = .null }
}

extension WorkflowValue: ExpressibleByDictionaryLiteral, ExpressibleByArrayLiteral {
  public init(dictionaryLiteral elements: (String, WorkflowValue)...) {
    self = .object(Dictionary(uniqueKeysWithValues: elements))
  }

  public init(arrayLiteral elements: WorkflowValue...) {
    self = .array(elements)
  }
}

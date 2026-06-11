import Foundation
import CodansIPC

/// Shared output rendering — every `codans` subcommand funnels through here
/// so text-mode and JSON-mode stay byte-stable across commands.
public enum Renderer {
  /// Render a value in the chosen mode and write to stdout (or an
  /// injected sink for tests).
  public static func emit<T: Encodable & CustomStringConvertible>(
    _ value: T,
    mode: RenderMode,
    sink: (String) -> Void = { print($0) }
  ) throws {
    switch mode {
    case .json:
      sink(try jsonString(value))
    case .text:
      sink(value.description)
    }
  }

  /// Render a simple object (no typed struct). Convenience for one-off
  /// rendering — typed callers should use `emit(_:mode:sink:)` above.
  ///
  /// JSON mode goes through `JSONValue` + `JSONEncoder` so the output
  /// stays byte-stable with the typed path: pretty-printed, sorted keys,
  /// and forward-slashes left unescaped. `JSONSerialization` does not
  /// expose a "without escaping slashes" knob, so the typed path was the
  /// only one emitting `/tmp/...` literally — this convenience wrapper
  /// used to leak `\/tmp\/...` and break shell-side jq pipelines.
  public static func emitObject(
    _ object: [String: Any],
    mode: RenderMode,
    textRender: (([String: Any]) -> String)? = nil,
    sink: (String) -> Void = { print($0) }
  ) throws {
    switch mode {
    case .json:
      let json = JSONValue.object(object.mapValues(Self.jsonValue(for:)))
      sink(try jsonString(json))
    case .text:
      if let textRender {
        sink(textRender(object))
      } else {
        let sorted = object.sorted { $0.key < $1.key }
        sink(sorted.map { "\($0.key): \($0.value)" }.joined(separator: "\n"))
      }
    }
  }

  private static func jsonString<T: Encodable>(_ value: T) throws -> String {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    let data = try encoder.encode(value)
    return String(bytes: data, encoding: .utf8) ?? ""
  }

  /// Lift a heterogenous `Any` (the `[String: Any]` payload callers build
  /// inline) into a `JSONValue`. Anything we don't recognise becomes a
  /// string via `String(describing:)` — better than throwing for what is
  /// already a best-effort convenience helper.
  private static func jsonValue(for any: Any) -> JSONValue {
    switch any {
    case let v as JSONValue: return v
    case is NSNull: return .null
    case let v as Bool: return .bool(v)
    case let v as Int: return .int(Int64(v))
    case let v as Int64: return .int(v)
    case let v as Double: return .double(v)
    case let v as String: return .string(v)
    case let v as [Any]: return .array(v.map(Self.jsonValue(for:)))
    case let v as [String: Any]: return .object(v.mapValues(Self.jsonValue(for:)))
    default: return .string(String(describing: any))
    }
  }
}

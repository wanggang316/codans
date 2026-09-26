import Foundation

/// A command's glyph: an SF Symbol, or a bundled `ToolMark`.
///
/// Persisted as a plain string in the fields that historically held only SF
/// Symbol names (`ScriptDefinition.systemImage`, and `Tab.icon` for tabs a
/// script spawns): a mark is written as `mark:<ToolMark.rawValue>`, mirroring
/// the `agent:` prefix of `TabIconRef`. No schema change: an older build reads
/// `mark:npm` as an unknown symbol name and simply draws nothing.
public nonisolated enum CommandIconRef: Hashable, Sendable {
  case symbol(String)
  case mark(ToolMark)

  static let markPrefix = "mark:"

  /// Parses a stored icon string. `nil` for an empty string and for a mark
  /// this build does not know (written by a newer build) — callers fall back
  /// to their default glyph rather than drawing a bogus symbol.
  public init?(storedValue: String) {
    let trimmed = storedValue.trimmingCharacters(in: .whitespaces)
    guard !trimmed.isEmpty else { return nil }
    if trimmed.hasPrefix(Self.markPrefix) {
      guard let mark = ToolMark(rawValue: String(trimmed.dropFirst(Self.markPrefix.count))) else { return nil }
      self = .mark(mark)
    } else {
      self = .symbol(trimmed)
    }
  }

  public var storedValue: String {
    switch self {
    case .symbol(let name): return name
    case .mark(let mark): return Self.markPrefix + mark.rawValue
    }
  }
}

extension ScriptDefinition {
  /// Glyph to draw: the per-command override when it parses, else the kind
  /// default. Prefer this over `resolvedSystemImage` at render sites — the
  /// latter is the raw stored string and may name a tool mark.
  public var resolvedIcon: CommandIconRef {
    systemImage.flatMap(CommandIconRef.init(storedValue:)) ?? .symbol(kind.defaultSystemImage)
  }
}

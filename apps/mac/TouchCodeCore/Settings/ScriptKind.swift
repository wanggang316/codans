import Foundation

/// Category of a `ScriptDefinition`. Supplies the default name, SF Symbol icon,
/// and tint colour. A per-command `systemImage` / `tintColor` override on
/// `ScriptDefinition` wins over these defaults regardless of kind; the kind
/// default applies only when no override is set.
public enum ScriptKind: String, Codable, Sendable, CaseIterable {
  case run
  case test
  case deploy
  case lint
  case format
  case custom

  /// User-facing default name when `ScriptDefinition.name` is empty.
  public var defaultName: String {
    switch self {
    case .run: return "Run"
    case .test: return "Test"
    case .deploy: return "Deploy"
    case .lint: return "Lint"
    case .format: return "Format"
    case .custom: return "Custom"
    }
  }

  /// SF Symbol name used when `ScriptDefinition.systemImage` is not set.
  public var defaultSystemImage: String {
    switch self {
    case .run: return "play.fill"
    case .test: return "checkmark.seal.fill"
    case .deploy: return "paperplane.fill"
    case .lint: return "magnifyingglass"
    case .format: return "wand.and.stars"
    case .custom: return "terminal.fill"
    }
  }

  /// Tint colour used when `ScriptDefinition.tintColor` is not set.
  public var defaultTintColor: ScriptTintColor {
    switch self {
    case .run: return .green
    case .test: return .yellow
    case .deploy: return .blue
    case .lint: return .purple
    case .format: return .teal
    case .custom: return .gray
    }
  }
}

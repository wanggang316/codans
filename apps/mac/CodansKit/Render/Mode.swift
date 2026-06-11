import Foundation

/// Output mode shared across every `codans` subcommand. `--json` flips to
/// machine-readable; default is human text.
public enum RenderMode: Sendable {
  case text(useColor: Bool)
  case json
}

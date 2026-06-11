import Foundation

/// Tint colour applied to a `ScriptDefinition`'s icon and (when used as the
/// primary script in `HeaderRunScriptSplitButton`) the button's accent face.
///
/// The raw values are stable lowercase tokens written to `settings.json`.
/// SwiftUI `Color` resolution lives view-side in a tiny helper so the model
/// layer stays UI-framework-free.
public enum ScriptTintColor: String, Codable, Sendable, CaseIterable {
  case green
  case yellow
  case red
  case blue
  case teal
  case purple
  case gray
}

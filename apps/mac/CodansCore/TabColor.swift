import SwiftUI

/// Per-tab accent color. `nil` on `Tab` means the system accent (default).
/// Palette matches `TagColor` (macOS Finder tag colors).
public nonisolated enum TabColor: String, Codable, CaseIterable, Sendable {
  case red
  case orange
  case yellow
  case green
  case blue
  case purple
  case grey

  public var swiftUIColor: Color {
    switch self {
    case .red: .red
    case .orange: .orange
    case .yellow: .yellow
    case .green: .green
    case .blue: .blue
    case .purple: .purple
    case .grey: .gray
    }
  }
}

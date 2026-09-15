import SwiftUI

/// One installable thing in the Developer pane — the CLI symlink or a
/// skill link for one agent: its mark, name, the path it lands at, and a
/// status dot beside the action button. Both sections render through this
/// row so they read as one list.
struct InstallTargetRow<Icon: View, Actions: View>: View {
  /// Glyph size shared by every row so brand marks and SF Symbols line up.
  static var iconSize: CGFloat { 24 }

  let title: String
  let subtitle: String
  /// Dot colour: green installed, secondary absent, orange needs attention.
  let tint: Color
  /// Spoken in place of the dot, which carries no text.
  let statusText: String
  @ViewBuilder let icon: () -> Icon
  @ViewBuilder let actions: () -> Actions

  var body: some View {
    HStack(spacing: 12) {
      icon()
      VStack(alignment: .leading, spacing: 2) {
        Text(title)
          .font(.body)
        Text(subtitle)
          .font(.caption)
          .foregroundStyle(.secondary)
          .lineLimit(1)
          .truncationMode(.middle)
      }
      Spacer(minLength: 0)
      Circle()
        .fill(tint)
        .frame(width: 8, height: 8)
        .accessibilityHidden(true)
      actions()
    }
    .padding(.vertical, 4)
    .accessibilityElement(children: .combine)
    .accessibilityLabel("\(title): \(statusText)")
  }
}

/// Bordered "Reveal in Finder" button both sections end with.
struct RevealInFinderButton: View {
  let action: () -> Void

  var body: some View {
    Button(action: action) {
      Label("Reveal in Finder", systemImage: "folder")
    }
    .buttonStyle(.bordered)
  }
}

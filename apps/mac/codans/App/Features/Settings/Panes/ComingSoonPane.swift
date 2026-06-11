import SwiftUI

/// Shared detail content for sections whose engine is not yet shipped (Shortcuts, Updates).
/// Spec M7: "Coming in a later release." The pane keeps the selection highlight but avoids
/// empty-state flicker by occupying the full detail frame.
struct ComingSoonPane: View {
  let title: String

  var body: some View {
    VStack(spacing: 8) {
      Text(title).font(.title3.bold())
      Text("Coming in a later release.")
        .foregroundStyle(.secondary)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
  }
}

#Preview {
  ComingSoonPane(title: "Shortcuts")
    .frame(width: 500, height: 300)
}

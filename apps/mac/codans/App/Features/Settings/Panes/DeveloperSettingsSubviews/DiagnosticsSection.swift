import SwiftUI
import CodansCore

/// Diagnostics buttons that escape users out to disk or the clipboard. All
/// behaviour lives behind `DeveloperPaneDependencies` closures so this view
/// remains previewable without AppKit singletons.
struct DiagnosticsSection: View {
  @Environment(DeveloperPaneDependencies.self) private var deps
  @State private var copyFeedback: String?

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      Text("Diagnostics").font(.headline)
      HStack(spacing: 8) {
        Button {
          deps.revealInFinder(Settings.defaultURL())
        } label: {
          Label("Reveal settings.json", systemImage: "folder")
        }
        .buttonStyle(.bordered)

        Button {
          let version = deps.bundleVersion().display
          deps.copyToPasteboard(version)
          copyFeedback = "Copied \(version)"
        } label: {
          Label("Copy app version", systemImage: "doc.on.doc")
        }
        .buttonStyle(.bordered)
      }
      HStack(spacing: 8) {
        Text("Version: \(deps.bundleVersion().display)")
          .font(.caption)
          .foregroundStyle(.secondary)
        if let feedback = copyFeedback {
          Text(feedback)
            .font(.caption)
            .foregroundStyle(.green)
            .transition(.opacity)
        }
      }
    }
  }
}

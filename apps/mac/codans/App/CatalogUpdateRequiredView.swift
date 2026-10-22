import CodansCore
import Dependencies
import SwiftUI

/// Main-window screen shown instead of the workspace when `catalog.json`
/// was written by a newer codans. The file is left as it is and nothing is
/// saved, so this build never overwrites the newer layout or touches the
/// sessions it names; updating codans is the way forward.
struct CatalogUpdateRequiredView: View {
  /// The catalog version found on disk.
  let fileVersion: Int

  @Dependency(UpdatesClient.self) private var updatesClient

  var body: some View {
    VStack(spacing: 12) {
      Image(systemName: "arrow.down.app")
        .font(.system(size: 48))
        .foregroundStyle(.secondary)
        .accessibilityHidden(true)
      Text("Update Required")
        .font(.title2)
        .fontWeight(.semibold)
      Text(
        "A newer version of codans saved your projects and layout. "
          + "Update codans to open them."
      )
      .foregroundStyle(.secondary)
      Text(
        "Until then nothing is saved and your terminal sessions keep running. "
          + "Catalog version \(fileVersion), this build reads up to \(Catalog.currentVersion)."
      )
      .font(.callout)
      .foregroundStyle(.tertiary)
      HStack(spacing: 8) {
        Button("Quit") { NSApp.terminate(nil) }
        Button("Check for Updates…") { updatesClient.checkNow() }
          .keyboardShortcut(.defaultAction)
      }
      .controlSize(.large)
      .padding(.top, 8)
    }
    .multilineTextAlignment(.center)
    .frame(maxWidth: 440)
    .padding(32)
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .background(Color(nsColor: .windowBackgroundColor))
    .accessibilityIdentifier("catalog_update_required")
  }
}

#Preview {
  CatalogUpdateRequiredView(fileVersion: 5)
    .frame(width: 800, height: 600)
}

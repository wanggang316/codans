import AppKit
import ComposableArchitecture
import Foundation

/// Thin TCA dependency over `NSOpenPanel` for picking a single local folder.
/// Exists so `HierarchySidebarFeature`'s Add Project flow can trigger the
/// macOS folder picker without importing AppKit into the reducer and so
/// `TestStore` can drive the flow with scripted URLs.
///
/// Distinct from `FinderClient` (which is reveal-only and returns `Void`):
/// the picker needs an async `URL?` return and a different dialog shape, so
/// keeping them separate avoids mixing two unrelated affordances.
nonisolated struct FolderPickerClient: Sendable {
  /// Shows a directory-only open pane with the given prompt. Returns the
  /// user's selection, or `nil` if they cancelled.
  var pick: @MainActor @Sendable (_ prompt: String) async -> URL?
}

extension FolderPickerClient: DependencyKey {
  static let liveValue = FolderPickerClient(
    pick: { prompt in
      await withCheckedContinuation { (continuation: CheckedContinuation<URL?, Never>) in
        Task { @MainActor in
          let panel = NSOpenPanel()
          panel.prompt = prompt
          panel.canChooseFiles = false
          panel.canChooseDirectories = true
          panel.allowsMultipleSelection = false
          panel.canCreateDirectories = true

          // Prefer attaching the panel as a sheet on the active window so the
          // picker visually belongs to the requesting context (codans's
          // main window in the common Add-Project flow). `runModal` would
          // float a free-standing window that can be dragged behind other
          // apps and dismissed without closing. Staying on AppKit means the
          // existing `FolderPickerClient` interface (`async URL?`) does
          // not have to migrate to a SwiftUI binding.
          let parent = NSApp.keyWindow ?? NSApp.mainWindow
          if let parent {
            panel.beginSheetModal(for: parent) { response in
              continuation.resume(returning: response == .OK ? panel.url : nil)
            }
          } else {
            // No window to anchor to (e.g. picker invoked before scene
            // attached). Fall back to a free-standing modal so the user
            // still gets a picker rather than the call hanging forever.
            let response = panel.runModal()
            continuation.resume(returning: response == .OK ? panel.url : nil)
          }
        }
      }
    }
  )

  static let testValue = FolderPickerClient(
    pick: unimplemented("FolderPickerClient.pick", placeholder: nil)
  )
}

extension DependencyValues {
  var folderPickerClient: FolderPickerClient {
    get { self[FolderPickerClient.self] }
    set { self[FolderPickerClient.self] = newValue }
  }
}

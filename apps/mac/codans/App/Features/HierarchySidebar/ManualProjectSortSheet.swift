import ComposableArchitecture
import SwiftUI
import CodansCore

/// Modal sheet for the "手动排序" entry of the sidebar's sort menu.
/// Renders the current manual order with draggable rows; "Done" writes
/// the resulting order back through `applyManualProjectOrder`, which
/// also flips `Catalog.projectSortMode` to `.manual` in one step.
///
/// The reducer owns the draft list (`State.manualSortSheet.orderedIDs`)
/// so a cancel discards it cleanly without touching the catalog.
///
/// Layout is a plain macOS sheet — a leading title header, the
/// reorderable list, then a trailing button bar — rather than an
/// iOS-style `NavigationStack`, so the panel reads as native AppKit.
struct ManualProjectSortSheetView: View {
  /// Snapshot of the projects (id + display name) — taken at sheet-open
  /// time from the parent view. Indexed by id for row rendering; the
  /// authoritative order lives in `store.manualSortSheet?.orderedIDs`.
  let projectNames: [ProjectID: String]
  @Bindable var store: StoreOf<HierarchySidebarFeature>

  var body: some View {
    let orderedIDs = store.manualSortSheet?.orderedIDs ?? []
    VStack(spacing: 0) {
      HStack {
        Text("Reorder Projects")
          .font(.headline)
        Spacer(minLength: 0)
      }
      .padding(.horizontal, 20)
      .padding(.top, 20)
      .padding(.bottom, 12)

      List {
        ForEach(orderedIDs, id: \.self) { id in
          HStack(spacing: 8) {
            Image(systemName: "line.3.horizontal")
              .foregroundStyle(.tertiary)
              .accessibilityHidden(true)
            Text(projectNames[id] ?? "Unknown")
              .lineLimit(1)
              .truncationMode(.middle)
            Spacer(minLength: 0)
          }
          .contentShape(Rectangle())
        }
        .onMove { source, destination in
          store.send(.manualSortRowsMoved(from: source, to: destination))
        }
      }
      .listStyle(.inset)

      Divider()

      // Native macOS button bar: trailing-aligned, Done is the default
      // (Return) button and renders prominent, Cancel maps to Escape.
      HStack(spacing: 12) {
        Spacer(minLength: 0)
        Button("Cancel") { store.send(.manualSortCancelled) }
          .keyboardShortcut(.cancelAction)
        Button("Done") { store.send(.manualSortConfirmed) }
          .keyboardShortcut(.defaultAction)
          .disabled(orderedIDs.isEmpty)
      }
      .padding(.horizontal, 20)
      .padding(.vertical, 14)
    }
    .frame(minWidth: 360, minHeight: 380)
  }
}

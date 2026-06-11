import ComposableArchitecture
import SwiftUI
import CodansCore

/// Modal sheet for the "手动排序" entry of the sidebar's sort popover.
/// Renders the current manual order with draggable rows; "完成" writes
/// the resulting order back through `applyManualProjectOrder`, which
/// also flips `Catalog.projectSortMode` to `.manual` in one step.
///
/// The reducer owns the draft list (`State.manualSortSheet.orderedIDs`)
/// so a cancel discards it cleanly without touching the catalog.
struct ManualProjectSortSheetView: View {
  /// Snapshot of the projects (id + display name) — taken at sheet-open
  /// time from the parent view. Indexed by id for row rendering; the
  /// authoritative order lives in `store.manualSortSheet?.orderedIDs`.
  let projectNames: [ProjectID: String]
  @Bindable var store: StoreOf<HierarchySidebarFeature>

  var body: some View {
    let orderedIDs = store.manualSortSheet?.orderedIDs ?? []
    NavigationStack {
      List {
        ForEach(orderedIDs, id: \.self) { id in
          HStack(spacing: 8) {
            Image(systemName: "line.3.horizontal")
              .foregroundStyle(.secondary)
              .accessibilityHidden(true)
            Text(projectNames[id] ?? "Unknown")
              .font(.body)
              .lineLimit(1)
              .truncationMode(.middle)
            Spacer()
          }
          .contentShape(Rectangle())
        }
        .onMove { source, destination in
          store.send(.manualSortRowsMoved(from: source, to: destination))
        }
      }
      .listStyle(.inset)
      .navigationTitle("Reorder Projects")
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button("Cancel") { store.send(.manualSortCancelled) }
        }
        ToolbarItem(placement: .confirmationAction) {
          Button("Done") { store.send(.manualSortConfirmed) }
            .disabled(orderedIDs.isEmpty)
        }
      }
    }
    .frame(minWidth: 380, minHeight: 360)
  }
}

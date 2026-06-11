import ComposableArchitecture
import Foundation
import CodansCore

/// Reducer for the Command Palette overlay. Owns the search query and
/// selection; rebuilds the item list on open and on each `queryChanged`
/// by running every built item through `CommandPaletteFuzzyScorer.score`.
///
/// Activation is lifted as `Delegate.activate(Kind)` for `RootFeature` to
/// pattern-match and forward to the feature action that already implements
/// the command. The palette itself executes nothing — it is pure routing.
@Reducer
struct CommandPaletteFeature {
  @ObservableState
  struct State: Equatable {
    var query: String = ""
    var selectionID: CommandPaletteItem.ID?
    var items: [CommandPaletteItem] = []
    var filtered: [CommandPaletteItem] = []
    /// `false` between `.appeared` and `.indexed` — the view shows just the
    /// query field while `CommandPaletteItems.build` runs in a follow-up
    /// effect. This is the difference between "no matches" (rendered as a
    /// hint) and "still indexing" (rendered as nothing) so the panel never
    /// flashes a stale empty-state.
    var isIndexed: Bool = false
    /// Read once from the parent on `.appeared`. Held here so filtering
    /// can blend the recency bonus into each keystroke without re-reading
    /// UserDefaults on the hot path. Writes land in the parent after
    /// `.delegate(.activate(…))` completes.
    var recency: [String: TimeInterval] = [:]
    /// Source pane for Pane/Window-scoped activations. Filled from the
    /// `.appeared` payload so `RootFeature.route` can target the right
    /// pane without re-reading the catalog.
    var focusedPaneID: PaneID?
  }

  enum Action: Equatable {
    /// Parent hands in every input needed to build the list in one shot:
    /// the selection, the catalog snapshot, installed editors, the
    /// persisted recency map, the pane to treat as focused for
    /// Window/Pane-scoped actions, and a flag indicating whether that
    /// pane was derived from a real focus event (ghostty keybind) or a
    /// fallback (menu trigger — the first leaf of the selected tab).
    case appeared(
      HierarchySelection,
      Catalog,
      [EditorDescriptor],
      [String: TimeInterval],
      PaneID?,
      Bool
    )
    /// Follow-up of `.appeared` carrying the built item list. Splitting these
    /// two phases lets the view render the query field on the same run-loop
    /// tick the palette appears, while the (cheap but synchronous) item build
    /// runs in a deferred Task — no perceived latency on Cmd-K.
    case indexed([CommandPaletteItem])
    case queryChanged(String)
    case selectionMoved(Direction)
    case selectionCommitted
    case rowTapped(CommandPaletteItem.ID)
    case delegate(Delegate)

    enum Direction: Equatable { case up, down }
    enum Delegate: Equatable { case activate(CommandPaletteItem.Kind) }
  }

  var body: some Reducer<State, Action> {
    Reduce { state, action in
      switch action {
      case .appeared(let selection, let catalog, let descriptors, let recency, let paneID, let precise):
        state.focusedPaneID = paneID
        state.recency = recency
        state.isIndexed = false
        state.items = []
        state.filtered = []
        state.selectionID = nil
        // Defer the item build to the next run-loop tick. The build itself is
        // in-memory but reads `SettingsWriter.readSnapshotSync` (MainActor) plus
        // a catalog walk; ~ms but enough to make Cmd-K feel laggy. Yielding
        // first lets SwiftUI paint the empty palette immediately.
        return .run { send in
          await Task.yield()
          let items = await MainActor.run {
            CommandPaletteItems.build(
              selection: selection,
              catalog: catalog,
              editorDescriptors: descriptors,
              focusedPaneID: paneID,
              paneFocusPrecise: precise
            )
          }
          await send(.indexed(items))
        }

      case .indexed(let items):
        state.items = items
        state.recency = CommandPalettePruner.prune(
          recency: state.recency, against: items
        )
        state.filtered = filter(items: items, query: state.query, recency: state.recency)
        state.selectionID = state.filtered.first?.id
        state.isIndexed = true
        return .none

      case .queryChanged(let query):
        state.query = query
        state.filtered = filter(items: state.items, query: query, recency: state.recency)
        state.selectionID = state.filtered.first?.id
        return .none

      case .selectionMoved(let direction):
        moveSelection(state: &state, direction: direction)
        return .none

      case .selectionCommitted:
        guard let id = state.selectionID ?? state.filtered.first?.id,
          let item = state.filtered.first(where: { $0.id == id })
        else { return .none }
        state.recency[item.id] = Date().timeIntervalSince1970
        return .send(.delegate(.activate(item.kind)))

      case .rowTapped(let id):
        guard let item = state.filtered.first(where: { $0.id == id }) else { return .none }
        state.recency[item.id] = Date().timeIntervalSince1970
        return .send(.delegate(.activate(item.kind)))

      case .delegate:
        return .none
      }
    }
  }

  private func filter(
    items: [CommandPaletteItem],
    query: String,
    recency: [String: TimeInterval]
  ) -> [CommandPaletteItem] {
    let now = Date().timeIntervalSince1970
    let scored: [(CommandPaletteItem, Int)] = items.compactMap { item in
      guard
        let score = CommandPaletteFuzzyScorer.score(
          item: item, query: query, recency: recency, now: now
        )
      else { return nil }
      return (item, score)
    }
    return
      scored
      .sorted { lhs, rhs in
        if lhs.1 != rhs.1 { return lhs.1 > rhs.1 }
        return lhs.0.title < rhs.0.title
      }
      .map(\.0)
  }

  private func moveSelection(state: inout State, direction: Action.Direction) {
    guard !state.filtered.isEmpty else {
      state.selectionID = nil
      return
    }
    let currentIndex =
      state.selectionID
      .flatMap { id in state.filtered.firstIndex(where: { $0.id == id }) } ?? 0
    let count = state.filtered.count
    let nextIndex: Int
    switch direction {
    case .up: nextIndex = (currentIndex - 1 + count) % count
    case .down: nextIndex = (currentIndex + 1) % count
    }
    state.selectionID = state.filtered[nextIndex].id
  }
}

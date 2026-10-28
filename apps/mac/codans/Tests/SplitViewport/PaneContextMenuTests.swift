import Foundation
import Testing
import CodansCore

@testable import Codans

/// Behavioural tests for `PaneContextMenuModel`. The SwiftUI view
/// itself is a thin wrapper that forwards to this model; testing the
/// model directly avoids spinning up a view tree while still pinning the
/// AC contracts on the production code path the menu drives.
///
/// AC coverage:
/// - AC-V11-M-001 / UT-V11-M-001: unmuted session reports `isMuted == false`.
/// - AC-V11-M-002 / UT-V11-M-002: toggle on unmuted writes `present: true`;
///   subsequent read on a muted session reports `isMuted == true`; toggle on
///   muted writes `present: false`.
@MainActor
struct PaneContextMenuTests {
  // MARK: - Fixtures

  /// Builds a single-project / single-worktree / single-pane / single-tab
  /// catalog. Returns the assembled catalog and the content id so tests can
  /// flip the session's `labels` without re-deriving identities.
  private func makeCatalog(paneLabels: Set<String> = []) -> (Catalog, ContentID) {
    let contentID = ContentID()
    let tab = Tab(
      name: "fixture", content: .terminal(id: contentID, workingDirectory: "/tmp", labels: paneLabels))
    let pane = Pane(tabs: [tab])
    let worktree = Worktree(
      id: WorktreeID(),
      name: "fixture",
      path: "/tmp",
      splitTree: SplitTree(leaf: pane.id),
      panes: [pane],
      focusedPaneID: pane.id
    )
    let project = Project(
      id: ProjectID(),
      name: "fixture",
      rootPath: "/tmp",
      worktrees: [worktree]
    )
    let catalog = Catalog(projects: [project])
    return (catalog, contentID)
  }

  /// Captures every `setLabel(contentID, label, present)` call so tests can
  /// assert on argument tuples without inspecting closure state.
  @MainActor
  private final class SetLabelRecorder {
    private(set) var calls: [(ContentID, String, Bool)] = []
    func record(_ contentID: ContentID, _ label: String, _ present: Bool) {
      calls.append((contentID, label, present))
    }
  }

  // MARK: - isMuted

  /// AC-V11-M-001: a freshly-spawned session carries no labels, so the menu
  /// reports `isMuted == false` and (in the view layer) renders the
  /// `bell.slash` glyph instead of the checkmark.
  @Test
  func isMutedFalseWhenLabelAbsent() {
    let (catalog, contentID) = makeCatalog(paneLabels: [])
    let recorder = SetLabelRecorder()
    let model = PaneContextMenuModel(
      contentID: contentID,
      snapshot: { catalog },
      setLabel: { contentID, label, present in
        recorder.record(contentID, label, present)
      }
    )

    #expect(model.isMuted == false)
    #expect(recorder.calls.isEmpty)
  }

  /// AC-V11-M-002 (read side): once `InboxLabels.muted` is present on the
  /// session, the menu reports `isMuted == true` and the next render shows
  /// the checkmark.
  @Test
  func isMutedTrueWhenLabelPresent() {
    let (catalog, contentID) = makeCatalog(paneLabels: [InboxLabels.muted])
    let recorder = SetLabelRecorder()
    let model = PaneContextMenuModel(
      contentID: contentID,
      snapshot: { catalog },
      setLabel: { contentID, label, present in
        recorder.record(contentID, label, present)
      }
    )

    #expect(model.isMuted == true)
    #expect(recorder.calls.isEmpty)
  }

  // MARK: - toggleMute

  /// AC-V11-M-002 (write side, unmuted → muted): toggling an unmuted session
  /// invokes `setLabel(contentID, InboxLabels.muted, true)` exactly once.
  @Test
  func toggleOnUnmutedRequestsLabelPresent() {
    let (catalog, contentID) = makeCatalog(paneLabels: [])
    let recorder = SetLabelRecorder()
    let model = PaneContextMenuModel(
      contentID: contentID,
      snapshot: { catalog },
      setLabel: { contentID, label, present in
        recorder.record(contentID, label, present)
      }
    )

    model.toggleMute()

    #expect(recorder.calls.count == 1)
    guard let call = recorder.calls.first else { return }
    #expect(call.0 == contentID)
    #expect(call.1 == InboxLabels.muted)
    #expect(call.2 == true)
  }

  /// AC-V11-M-002 (write side, muted → unmuted): toggling a muted session
  /// invokes `setLabel(contentID, InboxLabels.muted, false)` exactly once.
  @Test
  func toggleOnMutedRequestsLabelAbsent() {
    let (catalog, contentID) = makeCatalog(paneLabels: [InboxLabels.muted])
    let recorder = SetLabelRecorder()
    let model = PaneContextMenuModel(
      contentID: contentID,
      snapshot: { catalog },
      setLabel: { contentID, label, present in
        recorder.record(contentID, label, present)
      }
    )

    model.toggleMute()

    #expect(recorder.calls.count == 1)
    guard let call = recorder.calls.first else { return }
    #expect(call.0 == contentID)
    #expect(call.1 == InboxLabels.muted)
    #expect(call.2 == false)
  }

  // MARK: - close

  /// The "Close Tab" menu item fires the injected `closeTab` closure
  /// exactly once. The closure captures the Tab id at the view call site;
  /// the model only owns the firing, so this pins that contract.
  @Test
  func closeFiresCloseTabOnce() {
    let (catalog, contentID) = makeCatalog(paneLabels: [])
    var closeCount = 0
    let model = PaneContextMenuModel(
      contentID: contentID,
      snapshot: { catalog },
      setLabel: { _, _, _ in },
      closeTab: { closeCount += 1 }
    )

    model.close()

    #expect(closeCount == 1)
  }

  /// Reading and writing are independent — an unknown content id snapshots
  /// as `nil` and reports `isMuted == false` (no crash, no spurious
  /// label write). Guards the menu against the rare case where the session
  /// is removed from the catalog between menu-open and click.
  @Test
  func isMutedFalseWhenContentMissing() {
    let (catalog, _) = makeCatalog(paneLabels: [InboxLabels.muted])
    let foreignID = ContentID()
    let recorder = SetLabelRecorder()
    let model = PaneContextMenuModel(
      contentID: foreignID,
      snapshot: { catalog },
      setLabel: { contentID, label, present in
        recorder.record(contentID, label, present)
      }
    )

    #expect(model.isMuted == false)
  }
}

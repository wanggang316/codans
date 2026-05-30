import Foundation
import Testing
import TouchCodeCore

@testable import TouchCode

/// Section visibility is exposed as the pure
/// `ProjectGeneralSettingsView.visibleSections(for:)` function — that's
/// the testable surface for the kind-conditional render rule. SwiftUI's
/// view tree itself is not introspected here (snapshot tests are out of
/// scope per the M4 brief); the visibility set is the observable contract.
struct ProjectGeneralSettingsViewKindRenderTests {
  @Test
  func dirHidesGitOnlySections() {
    let visible = ProjectGeneralSettingsView.visibleSections(for: .dir)
    #expect(visible.contains(.general))
    #expect(visible.contains(.editor))
    #expect(visible.contains(.environment))
    #expect(!visible.contains(.gitViewer))
    #expect(!visible.contains(.worktree))
    #expect(!visible.contains(.github))
    #expect(!visible.contains(.lifecycle))
  }

  @Test
  func gitRepoShowsAllSections() {
    let visible = ProjectGeneralSettingsView.visibleSections(for: .gitRepo)
    #expect(visible == Set(ProjectGeneralSettingsView.SectionID.allCases))
    #expect(visible.count == 7)
    // Worktree-lifecycle script editors live at the bottom of this pane and
    // are git-only.
    #expect(visible.contains(.lifecycle))
  }

  @Test
  func sectionOrderingIsStableAcrossKinds() {
    // The Form renders Sections in declaration order, not Set order; this
    // test pins the canonical order so a future refactor cannot silently
    // shuffle sections. Lifecycle scripts render last.
    let canonical: [ProjectGeneralSettingsView.SectionID] = [
      .general, .editor, .gitViewer, .worktree, .github, .environment, .lifecycle,
    ]
    #expect(ProjectGeneralSettingsView.SectionID.allCases == canonical)
  }
}

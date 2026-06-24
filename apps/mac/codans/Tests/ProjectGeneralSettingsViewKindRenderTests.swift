import Foundation
import Testing
import CodansCore

@testable import Codans

/// Section visibility is exposed as the pure
/// `ProjectGeneralSettingsView.visibleSections(for:)` function — that's
/// the testable surface for the kind-conditional render rule. SwiftUI's
/// view tree itself is not introspected here (snapshot tests are out of
/// scope); the visibility set is the observable contract.
struct ProjectGeneralSettingsViewKindRenderTests {
  @Test
  func dirHidesGitOnlySections() {
    let visible = ProjectGeneralSettingsView.visibleSections(for: .dir)
    #expect(visible.contains(.general))
    #expect(visible.contains(.editor))
    #expect(visible.contains(.environment))
    #expect(!visible.contains(.worktree))
    #expect(!visible.contains(.github))
    #expect(!visible.contains(.lifecycle))
  }

  @Test
  func gitRepoShowsAllSections() {
    let visible = ProjectGeneralSettingsView.visibleSections(for: .gitRepo)
    #expect(visible == Set(ProjectGeneralSettingsView.SectionID.allCases))
    #expect(visible.count == 6)
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
      .general, .editor, .worktree, .github, .environment, .lifecycle,
    ]
    #expect(ProjectGeneralSettingsView.SectionID.allCases == canonical)
  }
}

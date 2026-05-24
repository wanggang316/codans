import Dependencies
import Foundation
import Testing
import TouchCodeCore

@testable import TouchCode

/// `CommandPaletteItems.build` produces different items depending on
/// selection state and catalog shape. Tests cover each context band.
@MainActor
struct CommandPaletteItemsTests {
  private static let emptyCatalog = Catalog()
  private static let emptySelection = HierarchySelection.empty

  /// `CommandPaletteItems.build` reads `SettingsWriter.readSnapshotSync` to
  /// surface per-Project scripts. Tests that don't care about scripts wrap
  /// build calls with this empty-settings override so the underlying
  /// `unimplemented` placeholder doesn't trip XCTFail.
  private static func withEmptySettings<R>(_ work: () throws -> R) rethrows -> R {
    try withDependencies {
      $0[SettingsWriter.self].readSnapshotSync = { Settings() }
    } operation: {
      try work()
    }
  }

  // MARK: - App-scope only

  @Test
  func emptyCatalogEmitsOnlyAppItems() {
    let items = CommandPaletteItems.build(
      selection: Self.emptySelection, catalog: Self.emptyCatalog
    )
    let ids = Set(items.map(\.id))
    #expect(ids.contains("app.open-settings"))
    #expect(ids.contains("app.check-for-updates"))
    #expect(ids.contains("app.quit"))
    #expect(!ids.contains("git.toggle-viewer"))
    #expect(!ids.contains("editor.open-default"))
    #expect(!ids.contains { $0.hasPrefix("pane.") })
    #expect(!ids.contains { $0.hasPrefix("window.") })
  }

  // MARK: - Worktree context

  @Test
  func worktreeSelectedEmitsWorktreeCommands() {
    var catalog = Catalog()
    var project = Project(name: "P", rootPath: "/tmp/p", gitRoot: "/tmp/p")
    let worktree = Worktree(name: "wt", path: "/tmp/p/wt", branch: "main")
    project.worktrees = [worktree]
    catalog.projects = [project]
    let selection = HierarchySelection(
      projectID: project.id, worktreeID: worktree.id
    )
    let items = Self.withEmptySettings {
      CommandPaletteItems.build(selection: selection, catalog: catalog)
    }
    let ids = Set(items.map(\.id))
    #expect(ids.contains("git.toggle-viewer"))
    #expect(ids.contains("editor.open-default"))
    #expect(ids.contains("editor.reveal-in-finder"))
    #expect(ids.contains("worktree.refresh"))
    #expect(ids.contains("worktree.close"))
    // worktree.close is hidden when query is empty.
    let closeItem = items.first { $0.id == "worktree.close" }
    #expect(closeItem?.hiddenWhenQueryEmpty == true)
  }

  @Test
  func editorDescriptorsBecomeOpenInItems() {
    var catalog = Catalog()
    var project = Project(name: "P", rootPath: "/tmp/p", gitRoot: "/tmp/p")
    let worktree = Worktree(name: "wt", path: "/tmp/p/wt", branch: "main")
    project.worktrees = [worktree]
    catalog.projects = [project]
    let selection = HierarchySelection(
      projectID: project.id, worktreeID: worktree.id
    )
    let descriptors = [
      EditorDescriptor(
        id: "vscode",
        displayName: "Visual Studio Code",
        bundleIdentifier: "com.microsoft.VSCode",
        launchMode: .directory,
        appURL: nil,
        alternateBundleIdentifiers: []
      ),
      EditorDescriptor(
        id: "zed",
        displayName: "Zed",
        bundleIdentifier: "dev.zed.Zed",
        launchMode: .directory,
        appURL: nil,
        alternateBundleIdentifiers: []
      ),
    ]
    let items = Self.withEmptySettings {
      CommandPaletteItems.build(
        selection: selection, catalog: catalog, editorDescriptors: descriptors
      )
    }
    let ids = Set(items.map(\.id))
    #expect(ids.contains("editor.open.vscode"))
    #expect(ids.contains("editor.open.zed"))
  }

  // MARK: - Focused pane resolution

  @Test
  func resolveFocusedPaneIDReturnsNilWhenNoSelection() {
    let id = CommandPaletteItems.resolveFocusedPaneID(
      selection: Self.emptySelection, catalog: Self.emptyCatalog
    )
    #expect(id == nil)
  }
}

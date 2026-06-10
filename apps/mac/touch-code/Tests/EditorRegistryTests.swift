import Foundation
import Testing
import TouchCodeCore

@testable import TouchCode

/// C8a Phase 6.1 — registry sanity coverage. Pins the shape of the 34-entry static registry:
/// size, ID uniqueness, bundle-ID invariants, and priority-list consistency. Catches both
/// accidental duplication (e.g. adding a new editor without pruning the old) and stale
/// references (priority lists citing IDs that no longer exist in the registry).
struct EditorRegistryTests {
  // MARK: - Shape

  @Test
  func registryHasThirtyFourEntries() {
    #expect(EditorRegistry.registry.count == 34)
  }

  @Test
  func registryIDsAreUnique() {
    let ids = EditorRegistry.registry.map(\.id)
    #expect(ids.count == Set(ids).count, "Duplicate editor IDs in registry: \(ids)")
  }

  // MARK: - Bundle ID invariants

  @Test
  func nonShellEditorRowsHaveNonEmptyBundleID() {
    for descriptor in EditorRegistry.registry where descriptor.launchMode != .shellEditor {
      #expect(
        !descriptor.bundleIdentifier.isEmpty,
        "Non-shell editor '\(descriptor.id)' must carry a bundle identifier"
      )
    }
  }

  @Test
  func shellEditorRowHasEmptyBundleIDAndCanonicalID() {
    let shellRows = EditorRegistry.registry.filter { $0.launchMode == .shellEditor }
    #expect(shellRows.count == 1, "Expected exactly one .shellEditor registry row")
    let row = try? #require(shellRows.first)
    #expect(row?.bundleIdentifier.isEmpty == true, ".shellEditor must have empty bundleIdentifier")
    #expect(row?.id == "editor", ".shellEditor row's id must be the canonical 'editor'")
    #expect(row?.appURL == nil, ".shellEditor row must have nil appURL in the registry template")
  }

  // MARK: - Priority lists

  @Test
  func editorPriorityOnlyReferencesKnownIDs() {
    let known = Set(EditorRegistry.registry.map(\.id))
    for id in EditorRegistry.editorPriority {
      #expect(known.contains(id), "editorPriority references unknown id '\(id)'")
    }
  }

  @Test
  func terminalPriorityOnlyReferencesKnownIDs() {
    let known = Set(EditorRegistry.registry.map(\.id))
    for id in EditorRegistry.terminalPriority {
      #expect(known.contains(id), "terminalPriority references unknown id '\(id)'")
    }
  }

  @Test
  func gitClientPriorityOnlyReferencesKnownIDs() {
    let known = Set(EditorRegistry.registry.map(\.id))
    for id in EditorRegistry.gitClientPriority {
      #expect(known.contains(id), "gitClientPriority references unknown id '\(id)'")
    }
  }

  @Test
  func defaultPriorityTerminatesAtFinder() {
    // Finder must be the LAST element: it is always installed, so if it appeared earlier
    // the priority walk would stop at Finder before reaching terminals (Ghostty, WezTerm)
    // and git clients (GitHub Desktop, Sourcetree) — making those IDs unreachable in
    // auto-resolution even when the user has them installed.
    #expect(
      EditorRegistry.defaultPriority.last == "finder",
      "defaultPriority must end with 'finder' so the always-installed terminator does not shadow later IDs"
    )
    #expect(
      EditorRegistry.defaultPriority.filter({ $0 == "finder" }).count == 1,
      "defaultPriority must contain exactly one 'finder' entry"
    )
  }

  @Test
  func menuOrderIncludesShellEditorAtEnd() {
    let order = EditorRegistry.menuOrder
    #expect(order.contains("editor"), "menuOrder must include the shell-editor 'editor' row")
    #expect(order.last == "editor", ".shellEditor entry must be at the tail of menuOrder")
  }

  @Test
  func menuOrderOnlyReferencesKnownIDs() {
    let known = Set(EditorRegistry.registry.map(\.id))
    for id in EditorRegistry.menuOrder {
      #expect(known.contains(id), "menuOrder references unknown id '\(id)'")
    }
  }

  // MARK: - Spot checks

  @Test
  func cursorRowBindsToToDesktopBundleID() {
    let cursor = EditorRegistry.registry.first(where: { $0.id == "cursor" })
    #expect(cursor?.bundleIdentifier == "com.todesktop.230313mzl4w4u92")
    #expect(cursor?.launchMode == .directory)
  }

  @Test
  func jetBrainsFamilyAllUseApplicationWithArguments() {
    let jetBrainsIDs: Set<EditorID> = ["intellij", "webstorm", "pycharm", "rubymine", "rustrover"]
    for id in jetBrainsIDs {
      let row = EditorRegistry.registry.first(where: { $0.id == id })
      #expect(row != nil, "Missing JetBrains entry: \(id)")
      #expect(
        row?.launchMode == .applicationWithArguments,
        "JetBrains entry '\(id)' must use .applicationWithArguments"
      )
    }
  }

  @Test
  func finderRowCarriesAppleBundleID() {
    let finder = EditorRegistry.registry.first(where: { $0.id == "finder" })
    #expect(finder?.bundleIdentifier == "com.apple.finder")
    #expect(finder?.launchMode == .directory)
  }
}

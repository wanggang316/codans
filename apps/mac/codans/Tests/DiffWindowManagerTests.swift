import AppKit
import CodansCore
import ComposableArchitecture
import SwiftUI
import Testing

@testable import Codans

@MainActor
struct DiffWindowManagerTests {
  @Test func oneWindowIsRetargetedAcrossWorktreesAndRestoresPreferences() async throws {
    let project = ProjectID()
    let first = WorktreeID()
    let second = WorktreeID()
    let manager = DiffWindowManager()
    let clock = TestClock()
    let files = [
      GitComparisonFile(path: "first.swift", status: "M"), GitComparisonFile(path: "second.swift", status: "M"),
    ]

    try await withDependencies {
      $0.continuousClock = clock
      $0[GitServiceClient.self].comparison = { url, scope, _ in
        GitComparisonSnapshot(scope: scope, baseLabel: "main", files: files, repositoryPath: url.path)
      }
      $0[GitServiceClient.self].comparisonListing = { url, scope, _ in
        GitComparisonSnapshot(scope: scope, baseLabel: "main", files: files, repositoryPath: url.path)
      }
      $0[GitServiceClient.self].comparisonContent = { _, _, _ in
        GitComparisonContent(oldText: "before", newText: "after")
      }
    } operation: {
      defer { diffWindow()?.close() }
      manager.open(
        projectID: project, worktreeID: first, path: "/tmp/diff-window-first", title: "First Diff",
        prBase: nil, prRepository: nil)
      let window = try #require(diffWindow())
      let store = try store(in: window)
      try await waitUntil { store.snapshot != nil && !store.contentLoading }

      manager.open(
        projectID: project, worktreeID: first, path: "/tmp/diff-window-first", title: "First Diff Updated",
        prBase: nil, prRepository: nil)
      #expect(diffWindow() === window)
      #expect(window.title == "First Diff Updated")
      #expect(diffWindowCount() == 1)
      #expect(window.frame.width >= DiffWindowManager.defaultContentSize.width)
      #expect(window.frame.height >= DiffWindowManager.defaultContentSize.height)
      #expect(window.parent == nil)
      #expect(window.level == .normal)
      #expect(window.toolbarStyle == .unified)
      #expect(window.styleMask.contains([.titled, .closable, .resizable, .miniaturizable, .fullSizeContentView]))

      store.send(.baseChanged("release"))
      store.send(.scopeChanged(.outgoing))
      store.send(.filePresentationChanged(.list))
      store.send(.layoutChanged("split"))
      try await waitUntil { store.snapshot?.scope == .outgoing && !store.contentLoading }
      store.send(.selectFile(files[1].id))
      try await waitUntil { store.selectedFileID == files[1].id && !store.contentLoading }

      manager.open(
        projectID: project, worktreeID: second, path: "/tmp/diff-window-second", title: "Second Diff",
        prBase: "develop", prRepository: nil)
      #expect(diffWindow() === window)
      #expect(diffWindowCount() == 1)
      #expect(window.title == "Second Diff")
      #expect(try self.store(in: window) === store)
      #expect(store.worktreeID == second)
      #expect(store.path == "/tmp/diff-window-second")
      #expect(store.prBase == "develop")
      #expect(store.state.scope == .all)
      #expect(store.base.isEmpty)
      #expect(store.filePresentation == .tree)
      #expect(store.layout == "unified")
      #expect(manager.toggleSidebar(in: window))
      #expect(!store.sidebarVisible)
      #expect(manager.toggleSidebar(in: window))
      #expect(store.sidebarVisible)
      store.send(.layoutChanged("split"))
      try await waitUntil { store.snapshot != nil && !store.contentLoading }

      window.close()
      #expect(window.contentView == nil)
      #expect(!store.isVisible)
      #expect(diffWindow() == nil)
      #expect(!manager.toggleSidebar(in: window))

      manager.open(
        projectID: project, worktreeID: first, path: "/tmp/diff-window-first", title: "First Diff Reopened",
        prBase: nil, prRepository: nil)
      let reopenedWindow = try #require(diffWindow())
      let reopenedStore = try self.store(in: reopenedWindow)
      #expect(reopenedWindow !== window)
      #expect(diffWindowCount() == 1)
      #expect(reopenedStore.state.scope == .outgoing)
      #expect(reopenedStore.base == "release")
      #expect(reopenedStore.layout == "split")
      #expect(reopenedStore.filePresentation == .list)
      #expect(reopenedStore.selectedFileID == files[1].id)
      try await waitUntil { reopenedStore.snapshot != nil && !reopenedStore.contentLoading }
      #expect(reopenedStore.selectedFileID == files[1].id)

      manager.open(
        projectID: project, worktreeID: second, path: "/tmp/diff-window-second", title: "Second Diff Reopened",
        prBase: nil, prRepository: nil)
      #expect(diffWindow() === reopenedWindow)
      #expect(reopenedStore.worktreeID == second)
      #expect(reopenedStore.layout == "split")
    }
  }

  private func diffWindow() -> NSWindow? {
    NSApp.windows.first { $0.identifier == DiffWindowManager.windowIdentifier && $0.contentView != nil }
  }

  private func diffWindowCount() -> Int {
    NSApp.windows.filter { $0.identifier == DiffWindowManager.windowIdentifier && $0.contentView != nil }.count
  }

  private func store(in window: NSWindow) throws -> StoreOf<DiffFeature> {
    try #require((window.contentViewController as? NSHostingController<DiffPanelView>)?.rootView.store)
  }

  private func waitUntil(_ condition: () -> Bool) async throws {
    for _ in 0..<100 {
      if condition() { return }
      try await Task.sleep(for: .milliseconds(10))
    }
    #expect(condition(), "The diff window did not finish loading mocked content.")
  }
}

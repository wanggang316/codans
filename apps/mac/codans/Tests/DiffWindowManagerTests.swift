import AppKit
import CodansCore
import ComposableArchitecture
import SwiftUI
import Testing

@testable import Codans

@MainActor
struct DiffWindowManagerTests {
  @Test func windowsAreIndependentAndReopeningRestoresPreferences() async throws {
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
      $0[GitServiceClient.self].comparisonContent = { _, _, _ in
        GitComparisonContent(oldText: "before", newText: "after")
      }
    } operation: {
      defer {
        window(for: first)?.close()
        window(for: second)?.close()
      }
      manager.open(
        projectID: project, worktreeID: first, path: "/tmp/diff-window-first", title: "First Diff",
        prBase: nil, prRepository: nil)
      let firstWindow = try #require(window(for: first))
      let firstStore = try store(in: firstWindow)
      try await waitUntil { firstStore.snapshot != nil && !firstStore.contentLoading }

      manager.open(
        projectID: project, worktreeID: first, path: "/tmp/diff-window-first", title: "First Diff Updated",
        prBase: nil, prRepository: nil)
      #expect(window(for: first) === firstWindow)
      #expect(firstWindow.title == "First Diff Updated")
      #expect(NSApp.windows.filter { $0.identifier?.rawValue == "diff-\(first)" && $0.contentView != nil }.count == 1)

      manager.open(
        projectID: project, worktreeID: second, path: "/tmp/diff-window-second", title: "Second Diff",
        prBase: nil, prRepository: nil)
      let secondWindow = try #require(window(for: second))
      let secondStore = try store(in: secondWindow)
      #expect(secondWindow !== firstWindow)
      #expect(firstStore.worktreeID == first)
      #expect(secondStore.worktreeID == second)
      #expect(manager.toggleSidebar(in: secondWindow))
      #expect(!secondStore.sidebarVisible)
      #expect(firstStore.sidebarVisible)
      #expect(manager.toggleSidebar(in: secondWindow))
      #expect(secondStore.sidebarVisible)
      #expect(firstWindow.frame.width >= 1000)
      #expect(firstWindow.frame.height >= 700)
      #expect(firstWindow.parent == nil)
      #expect(firstWindow.level == .normal)
      #expect(firstWindow.styleMask.contains([.titled, .closable, .resizable, .miniaturizable]))

      firstStore.send(.baseChanged("release"))
      #expect(firstWindow.toolbarStyle == .unified)
      #expect(firstWindow.styleMask.contains(.fullSizeContentView))
      firstStore.send(.scopeChanged(.outgoing))
      #expect(firstStore.filePresentation == .tree)
      firstStore.send(.filePresentationChanged(.list))
      #expect(secondStore.filePresentation == .tree)
      firstStore.send(.layoutChanged("split"))
      #expect(firstStore.layout == "split")
      #expect(secondStore.layout == "unified")
      try await waitUntil { firstStore.snapshot?.scope == .outgoing && !firstStore.contentLoading }
      firstStore.send(.selectFile(files[1].id))
      try await waitUntil { firstStore.selectedFileID == files[1].id && !firstStore.contentLoading }
      #expect(secondStore.state.scope == .all)
      #expect(secondStore.base.isEmpty)

      firstWindow.close()
      #expect(firstWindow.contentView == nil)
      #expect(!firstStore.isVisible)
      #expect(window(for: first) == nil)
      #expect(secondWindow.contentView != nil)
      #expect(secondStore.isVisible)

      manager.open(
        projectID: project, worktreeID: first, path: "/tmp/diff-window-first", title: "First Diff Reopened",
        prBase: nil, prRepository: nil)
      let reopenedWindow = try #require(window(for: first))
      let reopenedStore = try store(in: reopenedWindow)
      #expect(reopenedWindow !== firstWindow)
      #expect(reopenedStore.state.scope == .outgoing)
      #expect(reopenedStore.base == "release")
      #expect(reopenedStore.layout == "split")
      #expect(reopenedStore.filePresentation == .list)
      #expect(reopenedStore.selectedFileID == files[1].id)
      try await waitUntil { reopenedStore.snapshot != nil && !reopenedStore.contentLoading }
      #expect(reopenedStore.selectedFileID == files[1].id)
    }
  }

  private func window(for worktree: WorktreeID) -> NSWindow? {
    NSApp.windows.first { $0.identifier?.rawValue == "diff-\(worktree)" && $0.contentView != nil }
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

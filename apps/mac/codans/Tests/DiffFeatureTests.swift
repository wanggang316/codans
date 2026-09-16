import CodansCore
import ComposableArchitecture
import DiffViewKit
import Foundation
import Testing

@testable import Codans

@MainActor
struct DiffFeatureTests {
  private func populatedState(scope: GitComparisonScope = .all) -> DiffFeature.State {
    var state = DiffFeature.State()
    state.path = "/tmp/repository"
    state.scope = scope
    state.request = 4
    state.contentRequest = 7
    state.selectedFileID = "file.swift"
    state.snapshot = GitComparisonSnapshot(
      id: "snapshot", scope: scope, baseLabel: "main",
      files: [
        GitComparisonFile(path: "file.swift", status: "M")
      ], repositoryPath: "/tmp/repository")
    state.document = DiffDocument(id: "document", path: "file.swift", oldText: "old", newText: "new")
    return state
  }

  @Test func staleResponsesCannotReplaceCurrentContent() async {
    let store = TestStore(initialState: populatedState()) { DiffFeature() }
    await store.send(.contentLoaded(6, "previous.swift", .init(oldText: "stale", newText: "stale")))
    await store.send(.contentFailed(6, "stale failure"))
    await store.send(.failed(3, "stale failure"))
    await store.send(.loaded(3, .init(scope: .all, baseLabel: "old", files: [])))
  }

  @Test func changingScopeClearsContentAndInvalidatesResponses() async {
    let store = TestStore(initialState: populatedState()) { DiffFeature() }
    await store.send(.scopeChanged(.outgoing)) {
      $0.scope = .outgoing
      $0.request = 5
      $0.contentRequest = 8
      $0.snapshot = nil
      $0.document = nil
    }
    await store.receive(.refresh)
    await store.send(.contentLoaded(7, "file.swift", .init(oldText: "old", newText: "new")))
  }

  @Test func historicalSideNeverOpensEditor() async {
    let store = TestStore(initialState: populatedState()) { DiffFeature() }
    await store.send(.openFile("old", 12)) {
      $0.editorMessage = "This side is historical or deleted. Open the current file from the new side."
    }
  }

  @Test func deletedFileNeverOpensEditor() async {
    var state = populatedState()
    state.snapshot?.files[0].status = "D"
    let store = TestStore(initialState: state) { DiffFeature() }
    await store.send(.openFile("new", 12)) {
      $0.editorMessage = "This side is historical or deleted. Open the current file from the new side."
    }
  }

  @Test func outgoingOpensCurrentFileWithoutHistoricalLine() async {
    var state = populatedState(scope: .outgoing)
    state.isVisible = true
    let store = TestStore(initialState: state) {
      DiffFeature()
    } withDependencies: {
      $0.diffEditorClient.openFile = { root, file, line, _ in
        #expect(root.path == "/tmp/repository")
        #expect(file == "file.swift")
        #expect(line == nil)
      }
    }
    await store.send(.openFile("new", 12))
    await store.receive(.editorFinished(nil, "Opened current file; line navigation depends on the editor.")) {
      $0.editorMessage = "Opened current file; line navigation depends on the editor."
    }
  }

  @Test func baseDraftIsNotAppliedUntilRefresh() async {
    var state = populatedState(scope: .outgoing)
    state.isVisible = true
    state.base = "main"
    state.appliedBase = "main"
    let empty = GitComparisonSnapshot(id: "empty", scope: .outgoing, baseLabel: "main", files: [])
    let store = TestStore(initialState: state) {
      DiffFeature()
    } withDependencies: {
      $0.gitService.comparison = { _, _, base in
        #expect(base == "main")
        return empty
      }
    }
    await store.send(.baseChanged("release")) { $0.base = "release" }
    await store.send(.tick) {
      $0.request = 5
      $0.loading = true
    }
    store.exhaustivity = .off(showSkippedAssertions: false)
    await store.receive(.loaded(5, empty))
    #expect(store.state.appliedBase == "main")
    #expect(store.state.base == "release")
    #expect(store.state.document == nil)
  }
  @Test func emptySnapshotInvalidatesInFlightContent() async {
    var state = populatedState()
    state.contentLoading = true
    let store = TestStore(initialState: state) { DiffFeature() }
    store.exhaustivity = .off(showSkippedAssertions: false)
    await store.send(.loaded(4, .init(scope: .all, baseLabel: "HEAD", files: [])))
    #expect(store.state.contentRequest > 7)
    #expect(!store.state.contentLoading)
    await store.send(.contentLoaded(7, "file.swift", .init(oldText: "stale", newText: "stale")))
    #expect(store.state.document == nil)
  }

  @Test func changedWorkingFileDropsStaleLineNumber() async {
    var state = populatedState()
    state.isVisible = true
    let store = TestStore(initialState: state) {
      DiffFeature()
    } withDependencies: {
      $0.gitService.comparisonContent = { _, _, _ in .init(oldText: "old", newText: "changed again") }
      $0.diffEditorClient.openFile = { _, _, line, _ in #expect(line == nil) }
    }
    await store.send(.openFile("new", 12))
    await store.receive(.editorFinished(nil, "Opened current file; line navigation depends on the editor.")) {
      $0.editorMessage = "Opened current file; line navigation depends on the editor."
    }
  }

  @Test func staleEditorReplyCannotChangeAnotherWorktree() async {
    var state = populatedState()
    state.isVisible = true
    state.worktreeID = WorktreeID()
    let store = TestStore(initialState: state) { DiffFeature() }
    await store.send(.editorFinished(WorktreeID(), "Stale editor reply"))
  }

}

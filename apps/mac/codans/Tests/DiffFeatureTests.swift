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
    await store.send(.lineCountsLoaded(3, .init(scope: .all, baseLabel: "old", files: [])))
  }

  @Test func switchingToAnUncachedScopeClearsContentAndInvalidatesResponses() async {
    let store = TestStore(initialState: populatedState()) { DiffFeature() }
    await store.send(.scopeChanged(.outgoing)) {
      $0.scopeSelections[.all] = "file.swift"
      $0.scope = .outgoing
      $0.request = 5
      $0.contentRequest = 8
      $0.document = nil
    }
    await store.receive(.refresh)
    await store.send(.contentLoaded(7, "file.swift", .init(oldText: "old", newText: "new")))
    #expect(store.state.snapshots[.all]?.id == "snapshot")
  }

  @Test func switchingBackShowsTheCachedComparisonWhileRefreshing() async {
    var state = populatedState()
    state.isVisible = true
    let outgoing = GitComparisonSnapshot(
      id: "outgoing", scope: .outgoing, baseLabel: "origin/main",
      files: [GitComparisonFile(path: "pushed.swift", status: "M")])
    state.snapshots[.outgoing] = outgoing
    state.scopeSelections[.outgoing] = "pushed.swift"
    let store = TestStore(initialState: state) {
      DiffFeature()
    } withDependencies: {
      $0.gitService.comparison = { _, scope, _ in
        #expect(scope == .outgoing)
        return outgoing
      }
      $0.gitService.comparisonContent = { _, _, file in .init(oldText: "old", newText: file.path) }
    }
    store.exhaustivity = .off(showSkippedAssertions: false)
    await store.send(.scopeChanged(.outgoing)) {
      $0.scopeSelections[.all] = "file.swift"
      $0.scope = .outgoing
      $0.selectedFileID = "pushed.swift"
      $0.contentLoading = true
    }
    // The cached list and selection show at once; the previous document stays until replaced.
    #expect(store.state.snapshot == outgoing)
    #expect(store.state.document?.path == "file.swift")
    await store.finish()
    await store.skipReceivedActions()
    #expect(store.state.document?.path == "pushed.swift")
    #expect(store.state.snapshot == outgoing)
  }

  @Test func firstLoadListsFilesBeforeCountingUntrackedLines() async {
    var state = DiffFeature.State()
    state.path = "/tmp/repository"
    state.isVisible = true
    let listing = GitComparisonSnapshot(
      id: "listing", scope: .all, baseLabel: "HEAD", files: [GitComparisonFile(path: "new.swift", status: "A")],
      pendingLineCounts: ["new.swift"])
    let counted = GitComparisonSnapshot(
      id: "listing", scope: .all, baseLabel: "HEAD",
      files: [GitComparisonFile(path: "new.swift", status: "A", additions: 3, deletions: 0)])
    let store = TestStore(initialState: state) {
      DiffFeature()
    } withDependencies: {
      $0.gitService.comparisonListing = { _, _, _ in listing }
      $0.gitService.comparisonLineCounts = { _, snapshot in
        #expect(snapshot == listing)
        return counted
      }
      $0.gitService.comparisonContent = { _, _, _ in .init(oldText: "", newText: "a\nb\nc\n") }
    }
    store.exhaustivity = .off(showSkippedAssertions: false)
    await store.send(.refresh)
    await store.receive(.loaded(1, listing)) {
      $0.snapshot = listing
      $0.selectedFileID = "new.swift"
    }
    await store.receive(.lineCountsLoaded(1, counted)) { $0.snapshot = counted }
    await store.finish()
  }

  @Test func selectingAFileKeepsThePreviousContentUntilTheNewOneArrives() async {
    var state = populatedState()
    state.snapshot?.files.append(GitComparisonFile(path: "other.swift", status: "M"))
    let store = TestStore(initialState: state) {
      DiffFeature()
    } withDependencies: {
      $0.gitService.comparisonContent = { _, _, _ in .init(oldText: "x", newText: "y") }
    }
    store.exhaustivity = .off(showSkippedAssertions: false)
    await store.send(.selectFile("other.swift")) {
      $0.selectedFileID = "other.swift"
      $0.contentRequest = 8
      $0.contentLoading = true
    }
    #expect(store.state.document?.path == "file.swift")
    await store.receive(\.contentLoaded)
    #expect(store.state.document?.path == "other.swift")
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

  @Test(arguments: ["", "release", "  "])
  func outgoingDefaultIgnoresPRAndHonorsAppliedBase(base: String) async {
    var state = DiffFeature.State()
    state.path = "/tmp/repository"
    let worktree = WorktreeID()
    state.worktreeID = worktree
    state.isVisible = true
    state.scope = .outgoing
    state.base = base
    let expectedBase = base.trimmingCharacters(in: .whitespacesAndNewlines)
    let snapshot = GitComparisonSnapshot(scope: .outgoing, baseLabel: "origin/main", files: [])
    let store = TestStore(initialState: state) {
      DiffFeature()
    } withDependencies: {
      $0.gitService.comparisonListing = { _, scope, resolvedBase in
        #expect(scope == .outgoing)
        #expect(resolvedBase == (expectedBase.isEmpty ? nil : expectedBase))
        return snapshot
      }
    }
    // PR updates neither refresh the comparison nor override its explicit or automatic base.
    let repository = URL(string: "https://github.com/another/fork")
    await store.send(.prBaseChanged(worktree, "release-pr", repository)) {
      $0.prBase = "release-pr"
      $0.prRepository = repository
    }
    await store.send(.refresh) {
      $0.appliedBase = base
      $0.request = 1
      $0.loading = true
    }
    await store.receive(.loaded(1, snapshot)) {
      $0.loading = false
      $0.snapshot = snapshot
      $0.contentRequest = 1
    }
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

  @Test func branchChoicesLoadOnDemand() async {
    var state = DiffFeature.State()
    state.isVisible = true
    state.path = "/tmp/repository"
    let inventory = BranchInventory(
      current: "feature/review",
      local: [.init(shortName: "main", isRemote: false, upstream: "origin/main")],
      remote: [.init(shortName: "origin/main", isRemote: true, upstream: nil)])
    let store = TestStore(initialState: state) {
      DiffFeature()
    } withDependencies: {
      $0.gitService.listAllBranches = { path in
        #expect(path.path == "/tmp/repository")
        return inventory
      }
    }
    await store.send(.loadBaseBranches) {
      $0.baseBranchesLoading = true
      $0.baseBranchesRequest = 1
    }
    await store.receive(.baseBranchesLoaded(1, inventory)) {
      $0.baseBranchesLoading = false
      $0.baseBranches = inventory
    }
  }

  @Test func branchChoicesReportFailureAndCanRetry() async {
    var state = DiffFeature.State()
    state.isVisible = true
    state.path = "/tmp/repository"
    state.baseBranchesError = "Previous failure"
    let store = TestStore(initialState: state) {
      DiffFeature()
    } withDependencies: {
      $0.gitService.listAllBranches = { _ in throw GitError.timedOut }
    }
    await store.send(.loadBaseBranches) {
      $0.baseBranchesLoading = true
      $0.baseBranchesError = nil
      $0.baseBranchesRequest = 1
    }
    await store.receive(.baseBranchesFailed(1, "Git timed out. Refresh to try again.")) {
      $0.baseBranchesLoading = false
      $0.baseBranchesError = "Git timed out. Refresh to try again."
    }
    store.dependencies.gitService.listAllBranches = { _ in
      BranchInventory(current: "main", local: [], remote: [])
    }
    await store.send(.loadBaseBranches) {
      $0.baseBranchesLoading = true
      $0.baseBranchesError = nil
      $0.baseBranchesRequest = 2
    }
    let inventory = BranchInventory(current: "main", local: [], remote: [])
    await store.receive(.baseBranchesLoaded(2, inventory)) {
      $0.baseBranchesLoading = false
      $0.baseBranches = inventory
    }
  }

  @Test(arguments: [false, true])
  func branchChoicesAreInvalidatedOnCloseOrContextChange(close: Bool) async {
    var state = DiffFeature.State()
    state.path = "/tmp/repository"
    state.baseBranchesRequest = 3
    state.baseBranchesLoading = true
    let inventory = BranchInventory(current: "main", local: [], remote: [])
    state.baseBranches = inventory
    state.baseBranchesError = "Previous failure"
    let store = TestStore(initialState: state) { DiffFeature() }
    await store.send(close ? .close : .contextChanged(nil, nil, "/tmp/another-repository")) {
      if !close { $0.path = "/tmp/another-repository" }
      $0.request = 1
      $0.contentRequest = 1
      $0.baseBranchesRequest = 4
      $0.baseBranchesLoading = false
      $0.baseBranches = nil
      $0.baseBranchesError = nil
    }
    await store.send(.baseBranchesLoaded(3, inventory))
    await store.send(.baseBranchesFailed(3, "Stale failure"))
  }

  @Test(arguments: ["refs/remotes/origin/main", "refs/heads/release", ""])
  func selectingBaseImmediatelyRefreshesComparison(base: String) async {
    var state = DiffFeature.State()
    state.path = "/tmp/repository"
    state.isVisible = true
    state.scope = .outgoing
    state.base = "refs/heads/previous"
    state.appliedBase = state.base
    let snapshot = GitComparisonSnapshot(scope: .outgoing, baseLabel: "selected", files: [])
    let store = TestStore(initialState: state) {
      DiffFeature()
    } withDependencies: {
      $0.gitService.comparisonListing = { _, scope, selectedBase in
        #expect(scope == .outgoing)
        #expect(selectedBase == (base.isEmpty ? nil : base))
        return snapshot
      }
    }
    await store.send(.baseSelected(base)) { $0.base = base }
    await store.receive(.refresh) {
      $0.appliedBase = base
      $0.request = 1
      $0.loading = true
    }
    await store.receive(.loaded(1, snapshot)) {
      $0.loading = false
      $0.snapshot = snapshot
      $0.contentRequest = 1
    }
  }

}

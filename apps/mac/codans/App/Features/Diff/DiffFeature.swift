import CodansCore
import ComposableArchitecture
import DiffViewKit
import Foundation

@Reducer
struct DiffFeature {
  @ObservableState
  struct State: Equatable {
    var projectID: ProjectID?
    var worktreeID: WorktreeID?
    var path: String?
    var isVisible = false
    var filePresentation: FilePresentation = .tree
    var layout = "unified"
    var scope: GitComparisonScope = .all
    var base = ""
    var appliedBase = ""
    var prBase: String?
    var prRepository: URL?
    var filter = ""
    var snapshot: GitComparisonSnapshot?
    var selectedFileID: String?
    var document: DiffDocument?
    var notice: String?
    var error: String?
    var editorMessage: String?
    var rendererFailed = false
    var rendererGeneration = 0
    var loading = false
    var contentLoading = false
    var request = 0
    var contentRequest = 0
    var preferences: [WorktreeID: Preference] = [:]
  }

  struct Preference: Equatable {
    var scope: GitComparisonScope
    var base: String
    var selectedFileID: String?
    var filePresentation: FilePresentation = .tree
    var layout = "unified"
  }

  enum FilePresentation: String, Equatable, Sendable { case tree, list }

  enum Action: Equatable {
    case contextChanged(ProjectID?, WorktreeID?, String?)
    case prBaseChanged(WorktreeID, String?, URL?)
    case toggle
    case close
    case filePresentationChanged(FilePresentation)
    case layoutChanged(String)
    case scopeChanged(GitComparisonScope)
    case baseChanged(String)
    case filterChanged(String)
    case refresh
    case tick
    case loaded(Int, GitComparisonSnapshot)
    case failed(Int, String)
    case selectFile(String)
    case contentLoaded(Int, String, GitComparisonContent)
    case contentFailed(Int, String)
    case openFile(String, Int?)
    case editorFinished(WorktreeID?, String)
    case rendererFailed(String)
  }

  nonisolated enum CancelID: Hashable, Sendable { case refresh, content, timer, editor }
  @Dependency(GitServiceClient.self) var git
  @Dependency(DiffEditorClient.self) var editor
  @Dependency(\.continuousClock) var clock

  var body: some Reducer<State, Action> {
    Reduce { state, action in
      switch action {
      case .contextChanged(let project, let worktree, let path):
        guard state.worktreeID != worktree || state.path != path else { return .none }
        if let id = state.worktreeID {
          state.preferences[id] = Preference(
            scope: state.scope, base: state.base, selectedFileID: state.selectedFileID,
            filePresentation: state.filePresentation, layout: state.layout)
        }
        let preference = worktree.flatMap { state.preferences[$0] }
        state.projectID = project
        state.worktreeID = worktree
        state.path = path
        state.scope = preference?.scope ?? .all
        state.layout = preference?.layout ?? "unified"
        state.filePresentation = preference?.filePresentation ?? .tree
        state.base = preference?.base ?? ""
        state.appliedBase = state.base
        state.selectedFileID = preference?.selectedFileID
        state.prBase = nil
        state.prRepository = nil
        state.filter = ""
        clear(&state)
        return .merge(
          .cancel(id: CancelID.content), .cancel(id: CancelID.refresh), state.isVisible ? .send(.refresh) : .none)
      case .prBaseChanged(let worktree, let base, let repository):
        guard worktree == state.worktreeID else { return .none }
        let changed = state.prBase != base || state.prRepository != repository
        state.prBase = base
        state.prRepository = repository
        return changed && state.isVisible && state.scope == .outgoing && state.base.isEmpty ? .send(.refresh) : .none
      case .toggle:
        if state.isVisible { return .send(.close) }
        state.isVisible = true
        return .merge(
          .send(.refresh),
          .run { [clock] send in
            while !Task.isCancelled {
              try await clock.sleep(for: .seconds(2))
              await send(.tick)
            }
          }.cancellable(id: CancelID.timer, cancelInFlight: true))
      case .close:
        state.isVisible = false
        state.loading = false
        state.contentLoading = false
        state.request += 1
        state.contentRequest += 1
        return .merge(
          .cancel(id: CancelID.timer), .cancel(id: CancelID.refresh), .cancel(id: CancelID.content),
          .cancel(id: CancelID.editor))
      case .filePresentationChanged(let presentation):
        state.filePresentation = presentation
        return .none
      case .layoutChanged(let layout):
        guard layout == "unified" || layout == "split" else { return .none }
        state.layout = layout
        return .none
      case .scopeChanged(let scope):
        state.scope = scope
        clear(&state)
        return .send(.refresh)
      case .baseChanged(let value):
        state.base = value
        return .none
      case .filterChanged(let value):
        state.filter = value
        return .none
      case .tick:
        guard state.isVisible, !state.loading, !state.contentLoading else { return .none }
        return load(&state, silent: true)
      case .refresh:
        guard state.isVisible else { return .none }
        state.appliedBase = state.base
        if state.rendererFailed {
          state.rendererGeneration += 1
          state.rendererFailed = false
          state.editorMessage = nil
        }
        return load(&state, silent: false)
      case .loaded(let request, let snapshot):
        guard request == state.request else { return .none }
        state.loading = false
        state.error = nil
        state.snapshot = snapshot
        guard let file = snapshot.files.first(where: { $0.id == state.selectedFileID }) ?? snapshot.files.first else {
          state.contentRequest += 1
          state.contentLoading = false
          state.selectedFileID = nil
          state.document = nil
          state.notice = nil
          return .none
        }
        return select(&state, file: file, silent: file.id == state.selectedFileID)
      case .failed(let request, let message):
        guard request == state.request else { return .none }
        state.loading = false
        state.error = message
        state.contentRequest += 1
        state.contentLoading = false
        state.document = nil
        state.snapshot = nil
        return .none
      case .selectFile(let id):
        guard let file = state.snapshot?.files.first(where: { $0.id == id }) else { return .none }
        return select(&state, file: file, silent: false)
      default:
        return contentAction(&state, action)
      }
    }
  }

  private func clear(_ state: inout State) {
    state.request += 1
    state.contentRequest += 1
    state.snapshot = nil
    state.document = nil
    state.notice = nil
    state.error = nil
    state.editorMessage = nil
    state.loading = false
    state.contentLoading = false
  }

  private func load(_ state: inout State, silent: Bool) -> Effect<Action> {
    guard let path = state.path else {
      state.error = "Select a worktree to view changes."
      return .none
    }
    state.request += 1
    let request = state.request
    state.loading = true
    if !silent { state.error = nil }
    let scope = state.scope
    let prBase = state.prBase
    let prRepository = state.prRepository
    let base = state.appliedBase.trimmingCharacters(in: .whitespacesAndNewlines)
    return .run { [git] send in
      do {
        var selectedBase: String? = base.isEmpty ? nil : base
        if selectedBase == nil, scope == .outgoing, let prBase, let prRepository {
          let remote = try await git.remoteInfo(URL(fileURLWithPath: path))
          let expectedPath = "\(remote.owner)/\(remote.repo)"
          if prRepository.host?.lowercased() == remote.host.lowercased(),
            prRepository.path.trimmingCharacters(in: CharacterSet(charactersIn: "/")).lowercased()
              == expectedPath.lowercased()
          {
            selectedBase = "origin/\(prBase)"
          } else {
            throw GitError.invalidInput("Select a local ref for this PR's target repository.")
          }
        }
        let snapshot = try await git.comparison(URL(fileURLWithPath: path), scope, selectedBase)
        await send(.loaded(request, snapshot))
      } catch { await send(.failed(request, Self.errorMessage(error))) }
    }.cancellable(id: CancelID.refresh, cancelInFlight: true)
  }

  private func select(_ state: inout State, file: GitComparisonFile, silent: Bool) -> Effect<Action> {
    guard let snapshot = state.snapshot, let path = state.path else { return .none }
    state.selectedFileID = file.id
    state.contentRequest += 1
    let request = state.contentRequest
    state.contentLoading = true
    if !silent {
      state.document = nil
      state.notice = nil
      state.editorMessage = nil
    }
    return .run { [git] send in
      do {
        let content = try await git.comparisonContent(URL(fileURLWithPath: path), snapshot, file)
        await send(.contentLoaded(request, file.path, content))
      } catch { await send(.contentFailed(request, Self.errorMessage(error))) }
    }.cancellable(id: CancelID.content, cancelInFlight: true)
  }

  private func contentAction(_ state: inout State, _ action: Action) -> Effect<Action> {
    switch action {
    case .contentLoaded(let request, let path, let content):
      guard request == state.contentRequest else { return .none }
      state.contentLoading = false
      state.notice = content.notice
      guard content.notice == nil else {
        state.document = nil
        return .none
      }
      if state.document?.path != path || state.document?.oldText != content.oldText
        || state.document?.newText != content.newText
      {
        state.document = DiffDocument(
          id: UUID().uuidString, path: path, oldText: content.oldText, newText: content.newText)
      }
      return .none
    case .contentFailed(let request, let message):
      guard request == state.contentRequest else { return .none }
      state.contentLoading = false
      state.document = nil
      state.notice = message
      return .none
    case .rendererFailed(let message):
      state.rendererFailed = true
      state.editorMessage = message + " Use Refresh to reload the preview."
      return .none
    case .openFile(let side, let line):
      return openFile(&state, side: side, line: line)
    case .editorFinished(let worktree, let message):
      guard worktree == state.worktreeID, state.isVisible else { return .none }
      state.editorMessage = message
      return .none
    default: return .none
    }
  }

  private func openFile(_ state: inout State, side: String, line: Int?) -> Effect<Action> {
    guard let path = state.path, let snapshot = state.snapshot,
      let file = snapshot.files.first(where: { $0.id == state.selectedFileID })
    else { return .none }
    guard side == "new", file.status != "D" else {
      state.editorMessage = "This side is historical or deleted. Open the current file from the new side."
      return .none
    }
    let location = state.scope == .all || state.scope == .unstaged ? line : nil
    let displayedText = state.document?.newText
    let project = state.projectID
    let worktree = state.worktreeID
    return .run { [editor, git] send in
      do {
        var currentLine = location
        if currentLine != nil {
          let current = try await git.comparisonContent(URL(fileURLWithPath: path), snapshot, file)
          if current.newText != displayedText || current.notice != nil { currentLine = nil }
        }
        try await editor.openFile(URL(fileURLWithPath: path), file.path, currentLine, project)
        await send(.editorFinished(worktree, "Opened current file; line navigation depends on the editor."))
      } catch { await send(.editorFinished(worktree, Self.errorMessage(error))) }
    }.cancellable(id: CancelID.editor, cancelInFlight: true)
  }
  private nonisolated static func errorMessage(_ error: Error) -> String {
    guard let error = error as? GitError else { return error.localizedDescription }
    switch error {
    case .notARepo: return "This directory is not a Git repository."
    case .gitMissing: return "Git is unavailable. Install the Xcode command line tools."
    case .outputTooLarge, .diffTooLarge: return "The comparison exceeds the preview limit."
    case .timedOut: return "Git timed out. Refresh to try again."
    case .invalidInput(let message): return message
    case .exec(_, let stderr): return stderr.trimmingCharacters(in: .whitespacesAndNewlines)
    case .unparsable(let context): return "Cannot read this comparison: \(context)"
    case .malformedRemoteURL: return "Cannot resolve the repository remote for this comparison."
    }
  }

}

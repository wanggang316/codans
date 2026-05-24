import ComposableArchitecture
import Foundation
import TouchCodeCore

/// TCA reducer behind the Diff inspector + drawer.
///
/// Owns two separable workflows:
///   1. **Changed-files list** — driven by `worktreeSelected(...)`, fetched
///      via `GitServiceClient.diffNumstat`. Surfaces in the inspector.
///   2. **Per-file diff** — driven by `fileRowTapped(path:)`, fetched
///      lazily on first tap, cached in `diffsByPath`. Surfaces in the
///      drawer.
///
/// Cancellation:
///   - `CancelID.changedFiles` — cancels any prior changed-files load when
///     a new `worktreeSelected` arrives.
///   - `CancelID.diff(path)` — per-path slot; re-tapping the same row
///     while a load is in flight cancels the prior load.
///
/// Cap thresholds (`maxFileBytes`, `maxFileLines`) live as static
/// constants so tests can reference them without going through the
/// reducer instance.
@Reducer
struct DiffFeature {
  /// 500 KB. Above this, the drawer renders a "too large" placeholder.
  nonisolated static let maxFileBytes: Int = 500_000
  /// 5 000 lines. Above this on either side, same placeholder.
  nonisolated static let maxFileLines: Int = 5_000

  @ObservableState
  struct State: Equatable {
    /// Cached identifiers for the currently-active Worktree. Set by
    /// `worktreeSelected(...)`. `nil` means no Worktree is targeted —
    /// inspector renders an empty state.
    var worktreeID: WorktreeID?
    var projectID: ProjectID?
    var worktreePath: String?

    var changedFiles: ChangedFilesState = .idle
    /// Path of the file currently displayed in the drawer; `nil` = drawer
    /// hidden. Re-tapping the row whose path matches is a no-op.
    var presentedFilePath: String?
    /// Per-path diff cache. Survives drawer close — only cleared when
    /// `worktreeSelected(...)` switches to a different Worktree.
    var diffsByPath: [String: DiffEntryState] = [:]
    /// Mirrors `@AppStorage("diffStyle")`; the picker view writes both.
    var style: DiffStyle = .unified

    /// Right-panel tab routing for the inspector. Default `.changes` preserves
    /// pre-T11 behaviour: the inspector mounts straight onto the Changes body
    /// without forcing a tab switch on the first render.
    var selectedTab: DiffTab = .changes

    /// History tab cache + pagination. Reset on worktree switch and on the
    /// current worktree's HEAD changing (see `.headChangedForCurrentWorktree`).
    /// Empty `commits` + `loading == false + error == nil + hasMore == true`
    /// is the never-loaded sentinel; the view triggers the first page load
    /// from `.onAppear` via `.historyAppeared`.
    var historyState: HistoryState = .init()

    /// History-mode selection. Drives the left-side diff render when
    /// `selectedTab == .history`. Mutually independent of `presentedFilePath`
    /// — switching tabs does NOT clear either, so the user can ping-pong
    /// between Changes and History without losing the selected file or
    /// commit. Reset on worktree switch / HEAD change.
    var presentedCommitSha: String?

    /// Per-commit diff cache keyed by full SHA. Mirrors `diffsByPath`'s
    /// lifecycle: survives drawer close, reset only on worktree switch or
    /// HEAD change. Re-tapping a previously-rendered commit reuses the
    /// cached DiffDocument without re-fetch.
    var diffsByCommit: [String: DiffEntryState] = [:]
  }

  /// Routes the inspector's right panel between the Changes list (default,
  /// pre-T11 behaviour) and the History list (T11+). The user's tab choice
  /// survives worktree switches and HEAD changes; only an explicit
  /// `.tabSelected` action mutates it.
  enum DiffTab: Equatable, Sendable { case changes, history }

  /// Snapshot of the History tab's commit-list pagination plus the lifecycle
  /// flags the reducer guards on. The view treats `commits.isEmpty &&
  /// !loading && error == nil && hasMore` as the never-loaded sentinel and
  /// dispatches `.historyAppeared` on first render to trigger the initial
  /// page load.
  struct HistoryState: Equatable, Sendable {
    /// Loaded commits in display order (newest first; the order
    /// `GitServiceClient.log` returns).
    var commits: [Commit] = []

    /// Next offset to request. Always equals `commits.count`; promoted to
    /// a stored field for ergonomic guards on the load-more path.
    var nextOffset: Int = 0

    /// 50 per page — matches the design-doc target. Not user-tunable.
    var pageLimit: Int = 50

    /// True while a `gitService.log` call is in flight. Used to debounce
    /// `.historyLoadNextPageRequested` (re-entry while loading is a no-op).
    var loading: Bool = false

    /// `false` once the latest page returned fewer commits than `pageLimit`.
    /// New worktree / HEAD reset back to `true` so the first load can run.
    var hasMore: Bool = true

    /// Last load failure, if any. Surfaces in the view as an inline error
    /// row + retry button (T13). Cleared on next successful load.
    var error: GitError?
  }

  enum ChangedFilesState: Equatable {
    case idle
    case loading
    case loaded([ChangedFile])
    case error(GitError)
  }

  enum DiffEntryState: Equatable {
    case loading
    case loaded(LoadedDiffDocument)
    case error(GitError)
    case tooLarge(reason: TooLargeReason, copyCommand: String)
  }

  /// Reference wrapper for a loaded `DiffDocument`. Equality is identity-
  /// based (`===`) so `DiffEntryState.loaded` equality stays O(1) regardless
  /// of file size. SwiftUI re-evaluations rebuild State around the same
  /// instance, so a wrapper compares equal to itself by reference; a fresh
  /// load produces a new instance which compares unequal — the only two
  /// transitions we care about for view diffing.
  final class LoadedDiffDocument: Equatable, @unchecked Sendable {
    let document: DiffDocument
    init(_ document: DiffDocument) { self.document = document }
    static func == (lhs: LoadedDiffDocument, rhs: LoadedDiffDocument) -> Bool {
      lhs === rhs
    }
  }

  enum TooLargeReason: Equatable {
    case byteCount(Int)
    case lineCount(Int)
    case binary
  }

  enum Action: Equatable {
    case worktreeSelected(projectID: ProjectID?, worktreeID: WorktreeID?, path: String?)
    case refreshRequested
    case changedFilesSucceeded([ChangedFile])
    case changedFilesFailed(GitError)
    case fileRowTapped(path: String)
    case drawerCloseRequested
    case diffSucceededFor(path: String, document: DiffDocument)
    case diffFailedFor(path: String, error: GitError)
    case diffTooLargeFor(path: String, reason: TooLargeReason, copyCommand: String)
    case styleChanged(DiffStyle)
    case tabSelected(DiffTab)
    case historyAppeared
    case historyLoadNextPageRequested
    case historyPageSucceeded([Commit], hasMore: Bool)
    case historyPageFailed(GitError)
    /// Atomic "refresh the History tab" intent. Resets the cache + selection
    /// (same shape as `.headChangedForCurrentWorktree`) and re-fires
    /// `.historyAppeared` to kick the first-page load. Owned by FU-T12 so
    /// the refresh button and Retry button in `DiffHistoryListView` drive a
    /// single action instead of composing two sends from the view layer.
    case historyRefreshRequested
    case historyCommitTapped(sha: String)
    case commitDiffSucceededFor(sha: String, document: DiffDocument)
    case commitDiffFailedFor(sha: String, error: GitError)
    case commitDiffTooLargeFor(sha: String, reason: TooLargeReason, copyCommand: String)
    /// Forwarded by `RootFeature` when `WorktreeHeadWatcher` ticks for the
    /// active worktree. Resets `historyState`, `presentedCommitSha`, and
    /// `diffsByCommit` — the commit list shape is by definition stale.
    case headChangedForCurrentWorktree
  }

  /// `nonisolated` because TCA's `.cancellable(id:)` requires `Hashable & Sendable`.
  /// Flat enum without per-path payload — a single `.diff` slot ensures any
  /// in-flight per-file load is cancelled both when a new row is tapped and
  /// when the active Worktree changes, so a stale load can't write into the
  /// fresh Worktree's `diffsByPath`.
  nonisolated enum CancelID: Hashable, Sendable {
    case changedFiles
    case diff
    case historyPage
    case commitDiff
  }

  @Dependency(GitServiceClient.self) private var gitService

  var body: some Reducer<State, Action> {
    Reduce { state, action in
      switch action {
      case .worktreeSelected(let projectID, let worktreeID, let path):
        // Switching Worktree drops the prior cache; presentedFilePath
        // also resets so a stale drawer doesn't linger across switches.
        state.projectID = projectID
        state.worktreeID = worktreeID
        state.worktreePath = path
        state.presentedFilePath = nil
        state.diffsByPath = [:]
        // History side resets identically. `selectedTab` is NOT touched —
        // the user's tab preference persists across worktree switches.
        state.historyState = .init()
        state.presentedCommitSha = nil
        state.diffsByCommit = [:]
        guard worktreeID != nil, let path, !path.isEmpty else {
          state.changedFiles = .idle
          // Cancel any inflight loads from the previous worktree.
          return .merge(
            .cancel(id: CancelID.changedFiles),
            .cancel(id: CancelID.diff),
            .cancel(id: CancelID.historyPage),
            .cancel(id: CancelID.commitDiff)
          )
        }
        state.changedFiles = .loading
        return .merge(
          .cancel(id: CancelID.diff),
          .cancel(id: CancelID.historyPage),
          .cancel(id: CancelID.commitDiff),
          loadChangedFiles(at: path)
        )

      case .refreshRequested:
        // Re-issue the changed-files load using the cached path. The
        // per-file cache is preserved — refresh is meant for "I just
        // edited files in the worktree, recompute the list," not "I
        // switched Worktrees." (Decision Log D16.)
        guard let path = state.worktreePath, !path.isEmpty else { return .none }
        state.changedFiles = .loading
        return loadChangedFiles(at: path)

      case .changedFilesSucceeded(let files):
        state.changedFiles = .loaded(files)
        return .none

      case .changedFilesFailed(let error):
        state.changedFiles = .error(error)
        return .none

      case .fileRowTapped(let path):
        state.presentedFilePath = path
        // Cache hit on `.loaded` / `.tooLarge`: don't refetch (drawer
        // already shows the right content). `.error` falls through so the
        // Retry button can re-issue the load (FU-T14). `.loading` is the
        // in-flight case and also falls through — `.cancellable(cancelInFlight:
        // true)` on `CancelID.diff` cancels the prior load before issuing
        // the new one, so re-tapping a loaded row still no-ops via `.loaded`.
        switch state.diffsByPath[path] {
        case .loaded, .tooLarge: return .none
        case .error, .loading, .none: break
        }
        state.diffsByPath[path] = .loading
        guard let worktreePath = state.worktreePath, !worktreePath.isEmpty else {
          return .send(.diffFailedFor(path: path, error: .invalidInput("missing worktree path")))
        }
        return loadDiff(forPath: path, worktreePath: worktreePath)

      case .drawerCloseRequested:
        // Closes the drawer regardless of which tab opened it. Both
        // selection fields are cleared so a future re-open of the drawer
        // in either tab starts from no selection. Cache (`diffsByPath` /
        // `diffsByCommit`) is preserved — re-tapping a previously-
        // rendered row hits cache.
        state.presentedFilePath = nil
        state.presentedCommitSha = nil
        return .none

      case .diffSucceededFor(let path, let document):
        state.diffsByPath[path] = .loaded(LoadedDiffDocument(document))
        return .none

      case .diffFailedFor(let path, let error):
        state.diffsByPath[path] = .error(error)
        return .none

      case .diffTooLargeFor(let path, let reason, let copyCommand):
        state.diffsByPath[path] = .tooLarge(reason: reason, copyCommand: copyCommand)
        return .none

      case .styleChanged(let style):
        state.style = style
        return .none

      case .tabSelected(let tab):
        state.selectedTab = tab
        return .none

      case .historyRefreshRequested:
        // Atomic refresh: drop the prior cache + selection, cancel any
        // in-flight history / commit-diff effects, then re-fire
        // `.historyAppeared` to kick the first-page load. Same reset shape
        // as `.headChangedForCurrentWorktree`; the difference is intent —
        // refresh is user-initiated and unconditionally re-fetches.
        state.historyState = .init()
        state.presentedCommitSha = nil
        state.diffsByCommit = [:]
        return .merge(
          .cancel(id: CancelID.historyPage),
          .cancel(id: CancelID.commitDiff),
          .send(.historyAppeared)
        )

      case .historyAppeared:
        // Idempotent: only trigger first-page load when cache is genuinely
        // empty and not already loading. Subsequent rebinds (tab switch
        // back to History) re-trigger `.onAppear` but should be no-ops.
        // A pending error blocks re-fire too; T13's retry action will
        // own clearing it and re-issuing the load.
        guard state.historyState.commits.isEmpty,
          !state.historyState.loading,
          state.historyState.error == nil,
          let path = state.worktreePath, !path.isEmpty
        else { return .none }
        state.historyState.loading = true
        return loadHistoryPage(
          at: path,
          offset: state.historyState.nextOffset,
          limit: state.historyState.pageLimit
        )

      case .historyLoadNextPageRequested:
        guard state.historyState.hasMore,
          !state.historyState.loading,
          state.historyState.error == nil,
          let path = state.worktreePath, !path.isEmpty
        else { return .none }
        state.historyState.loading = true
        return loadHistoryPage(
          at: path,
          offset: state.historyState.nextOffset,
          limit: state.historyState.pageLimit
        )

      case .historyPageSucceeded(let commits, let hasMore):
        state.historyState.commits.append(contentsOf: commits)
        state.historyState.nextOffset = state.historyState.commits.count
        state.historyState.hasMore = hasMore
        state.historyState.loading = false
        state.historyState.error = nil
        return .none

      case .historyPageFailed(let error):
        state.historyState.loading = false
        state.historyState.error = error
        return .none

      case .historyCommitTapped(let sha):
        // Guard FIRST: a missing worktree path is a no-op rather than a
        // selection mutation, so the inspector never visually highlights a
        // commit we can't load. Cache hit on `.loaded` / `.tooLarge`: don't
        // refetch. `.error` falls through so the Retry button can re-issue
        // the load (FU-T14). `.loading` falls through too —
        // `.cancellable(cancelInFlight: true)` on `CancelID.commitDiff`
        // handles the in-flight overlap.
        guard let worktreePath = state.worktreePath, !worktreePath.isEmpty else {
          return .none
        }
        state.presentedCommitSha = sha
        switch state.diffsByCommit[sha] {
        case .loaded, .tooLarge: return .none
        case .error, .loading, .none: break
        }
        state.diffsByCommit[sha] = .loading
        return loadCommitDiff(sha: sha, worktreePath: worktreePath)

      case .commitDiffSucceededFor(let sha, let document):
        state.diffsByCommit[sha] = .loaded(LoadedDiffDocument(document))
        return .none

      case .commitDiffFailedFor(let sha, let error):
        state.diffsByCommit[sha] = .error(error)
        return .none

      case .commitDiffTooLargeFor(let sha, let reason, let copyCommand):
        state.diffsByCommit[sha] = .tooLarge(reason: reason, copyCommand: copyCommand)
        return .none

      case .headChangedForCurrentWorktree:
        // The commit list and any in-flight history fetch are stale by
        // definition. Drop the cache + per-commit cache + selection. Do
        // NOT touch `selectedTab` — user's tab choice survives HEAD
        // changes (same posture as `.worktreeSelected`).
        state.historyState = .init()
        state.presentedCommitSha = nil
        state.diffsByCommit = [:]
        return .merge(
          .cancel(id: CancelID.historyPage),
          .cancel(id: CancelID.commitDiff)
        )
      }
    }
  }

  // MARK: - Effect builders

  private func loadChangedFiles(at worktreePath: String) -> Effect<Action> {
    .run { [gitService] send in
      do {
        let files = try await gitService.diffNumstat(worktreePath)
        await send(.changedFilesSucceeded(files))
      } catch let error as GitError {
        await send(.changedFilesFailed(error))
      } catch {
        await send(.changedFilesFailed(.unparsable(context: "\(error)")))
      }
    }
    .cancellable(id: CancelID.changedFiles, cancelInFlight: true)
  }

  private func loadDiff(forPath path: String, worktreePath: String) -> Effect<Action> {
    .run { [gitService] send in
      do {
        // `git show HEAD:<path>` for the baseline; nil means the path is
        // newly added (no HEAD blob exists). Filesystem read for the
        // working-tree side; failure to read counts the file as deleted
        // (empty new contents).
        let oldContents = (try? await gitService.showFileAtHEAD(path, worktreePath)) ?? ""
        let newContentsURL = URL(fileURLWithPath: worktreePath).appendingPathComponent(path)
        let newContents = (try? String(contentsOf: newContentsURL, encoding: .utf8)) ?? ""

        // Cap checks. Byte count first (cheaper than splitting lines on
        // a half-megabyte string). Binary-detection lives upstream in
        // `diffNumstat`; if the per-file load reaches here it's textual.
        let oldBytes = oldContents.utf8.count
        let newBytes = newContents.utf8.count
        if oldBytes > Self.maxFileBytes || newBytes > Self.maxFileBytes {
          let reason = TooLargeReason.byteCount(max(oldBytes, newBytes))
          let cmd = Self.copyCommand(worktreePath: worktreePath, path: path)
          await send(.diffTooLargeFor(path: path, reason: reason, copyCommand: cmd))
          return
        }
        let oldLines = oldContents.split(separator: "\n", omittingEmptySubsequences: false).count
        let newLines = newContents.split(separator: "\n", omittingEmptySubsequences: false).count
        if oldLines > Self.maxFileLines || newLines > Self.maxFileLines {
          let reason = TooLargeReason.lineCount(max(oldLines, newLines))
          let cmd = Self.copyCommand(worktreePath: worktreePath, path: path)
          await send(.diffTooLargeFor(path: path, reason: reason, copyCommand: cmd))
          return
        }

        // `DiffFile` / `DiffDocument` are SwiftUI-adjacent types whose
        // initializers inherit the App target's MainActor default isolation —
        // hop onto the main actor to construct them, then send the result.
        let document = await MainActor.run { () -> DiffDocument in
          let file = DiffFile(
            oldPath: oldContents.isEmpty ? nil : path,
            newPath: newContents.isEmpty ? nil : path,
            oldContents: oldContents,
            newContents: newContents
          )
          return DiffDocument(files: [file], title: path)
        }
        await send(.diffSucceededFor(path: path, document: document))
      } catch let error as GitError {
        await send(.diffFailedFor(path: path, error: error))
      } catch {
        await send(.diffFailedFor(path: path, error: .unparsable(context: "\(error)")))
      }
    }
    .cancellable(id: CancelID.diff, cancelInFlight: true)
  }

  private func loadHistoryPage(
    at worktreePath: String,
    offset: Int,
    limit: Int
  ) -> Effect<Action> {
    .run { [gitService] send in
      do {
        let url = URL(fileURLWithPath: worktreePath)
        let cursor = LogPage.Cursor(offset: offset, limit: limit)
        let page = try await gitService.log(url, cursor)
        await send(.historyPageSucceeded(page.commits, hasMore: page.hasMore))
      } catch let error as GitError {
        await send(.historyPageFailed(error))
      } catch {
        await send(.historyPageFailed(.unparsable(context: "\(error)")))
      }
    }
    .cancellable(id: CancelID.historyPage, cancelInFlight: true)
  }

  /// Fetches the unified diff for a single commit and packages it into a
  /// `DiffDocument` via the renderer's `fallbackPatch` path. `UnifiedDiff` is
  /// the parsed shape — `FileChange` carries hunks but NOT pre/post-image
  /// file contents — so we can't construct `DiffFile(oldContents:,
  /// newContents:)` directly. Re-serialising the parsed diff back into its
  /// canonical unified-diff text is the cleanest bridge: the renderer's JS
  /// already accepts the `patch` field for exactly this case (see
  /// `DiffWebViewBridge.makeDocument`).
  private func loadCommitDiff(sha: String, worktreePath: String) -> Effect<Action> {
    .run { [gitService] send in
      do {
        let url = URL(fileURLWithPath: worktreePath)
        let unified = try await gitService.commitDiff(url, sha, false)
        let patch = Self.renderUnifiedDiffAsPatch(unified)
        let title = String(sha.prefix(7))
        let document = await MainActor.run { () -> DiffDocument in
          DiffDocument(files: [], title: title, fallbackPatch: patch)
        }
        await send(.commitDiffSucceededFor(sha: sha, document: document))
      } catch let error as GitError {
        await send(.commitDiffFailedFor(sha: sha, error: error))
      } catch {
        await send(.commitDiffFailedFor(sha: sha, error: .unparsable(context: "\(error)")))
      }
    }
    .cancellable(id: CancelID.commitDiff, cancelInFlight: true)
  }

  // MARK: - Helpers

  /// POSIX shell-quote a single argument by wrapping in single quotes and
  /// escaping any embedded single quote as `'\''`. Matches the helper the
  /// retired `LargeDiffCommand.swift` used (verified via git history at
  /// commit `e66f48b`).
  nonisolated static func copyCommand(worktreePath: String, path: String) -> String {
    "cd \(posixQuote(worktreePath)) && git diff \(posixQuote(path))"
  }

  nonisolated private static func posixQuote(_ s: String) -> String {
    "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
  }

  /// Serialises a parsed `UnifiedDiff` back into the canonical `git diff`
  /// text shape. Used to feed `DiffDocument.fallbackPatch` for commit-diff
  /// rendering, where we don't have the pre/post-image file contents the
  /// per-file path otherwise needs. The output retains enough header
  /// scaffolding (`diff --git`, `--- a/...`, `+++ b/...`, `@@ ...`) for the
  /// renderer's JS to identify file boundaries and hunk ranges.
  ///
  /// Not a perfect round-trip — mode / index / similarity headers from the
  /// original `git diff` output are not re-emitted because the parsed
  /// `FileChange` does not retain them. The renderer is tolerant of the
  /// minimal shape; merge / combined-diff input is out of scope (same
  /// boundary as `DiffParser`).
  nonisolated static func renderUnifiedDiffAsPatch(_ unified: UnifiedDiff) -> String {
    var out = ""
    for file in unified.files {
      let oldPath = oldPathForRender(file)
      let newPath = newPathForRender(file)
      out += "diff --git a/\(oldPath) b/\(newPath)\n"
      switch file.kind {
      case .added:
        out += "new file mode 100644\n"
      case .deleted:
        out += "deleted file mode 100644\n"
      case .renamed(let from):
        out += "rename from \(from)\n"
        out += "rename to \(file.id)\n"
      case .copied(let from):
        out += "copy from \(from)\n"
        out += "copy to \(file.id)\n"
      case .modified, .typeChanged:
        break
      }
      if file.isBinary {
        out += "Binary files a/\(oldPath) and b/\(newPath) differ\n"
        continue
      }
      if case .deleted = file.kind {
        out += "--- a/\(oldPath)\n+++ /dev/null\n"
      } else if case .added = file.kind {
        out += "--- /dev/null\n+++ b/\(newPath)\n"
      } else {
        out += "--- a/\(oldPath)\n+++ b/\(newPath)\n"
      }
      for hunk in file.hunks {
        // `hunk.header` is the raw header line as captured by the parser,
        // including the trailing section hint. Re-emit verbatim so the
        // renderer sees the same shape `git diff` would have produced.
        out += "\(hunk.header)\n"
        for line in hunk.lines {
          switch line.kind {
          case .context: out += " \(line.text)\n"
          case .added: out += "+\(line.text)\n"
          case .removed: out += "-\(line.text)\n"
          case .noNewlineMarker: out += "\\\(line.text)\n"
          }
        }
      }
    }
    return out
  }

  /// Pre-image path. For renames/copies the parsed model carries the source
  /// path inside `kind`; otherwise it equals `file.id` (which is the
  /// pre-image for deletions and the post-image for everything else — see
  /// `FileChange`'s docstring).
  nonisolated private static func oldPathForRender(_ file: FileChange) -> String {
    switch file.kind {
    case .renamed(let from), .copied(let from): return from
    default: return file.id
    }
  }

  /// Post-image path. Always `file.id` — for deletions the post-image is
  /// `/dev/null` (handled by the `--- a/ +++ /dev/null` branch above), but
  /// the `b/<path>` slot in the `diff --git` header conventionally repeats
  /// the pre-image path.
  nonisolated private static func newPathForRender(_ file: FileChange) -> String {
    file.id
  }
}

// MARK: - Inspector row model

/// One row in the Diff inspector. Built by `GitServiceClient.diffNumstat`
/// from `git diff --numstat -z` + `git diff --name-status -z`. `addedLines`
/// / `removedLines` are -1 sentinels for binary files (see `isBinary`).
///
/// `public` because the `GitService` protocol (also `public`) takes this
/// as a return type — Swift won't let a public method's result be
/// internal even when both live in the same module.
public nonisolated struct ChangedFile: Equatable, Identifiable, Sendable {
  public var id: String { newPath ?? oldPath ?? "" }
  public let oldPath: String?
  public let newPath: String?
  public let status: ChangeStatus
  public let addedLines: Int
  public let removedLines: Int
  public let isBinary: Bool

  public init(
    oldPath: String?,
    newPath: String?,
    status: ChangeStatus,
    addedLines: Int,
    removedLines: Int,
    isBinary: Bool
  ) {
    self.oldPath = oldPath
    self.newPath = newPath
    self.status = status
    self.addedLines = addedLines
    self.removedLines = removedLines
    self.isBinary = isBinary
  }
}

public nonisolated enum ChangeStatus: String, Equatable, Sendable {
  case modified
  case added
  case deleted
  case renamed
}

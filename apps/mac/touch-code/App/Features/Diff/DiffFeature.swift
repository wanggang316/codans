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
    /// True while a `.refreshRequested` revalidation runs with a prior
    /// `.loaded` list still on screen (stale-while-revalidate). Drives the
    /// header refresh button's spinner WITHOUT dropping `changedFiles` to
    /// `.loading` — which would clear the rows and blank the `(n)` count,
    /// the visible flash this flag exists to avoid. Reset on
    /// success / failure and on worktree switch.
    var isRefreshingChanges: Bool = false
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

    /// Lazily-fetched full commit messages keyed by sha. Populated on first
    /// hover; cached for the lifetime of the worktree (cleared on worktree
    /// change + head change). Stored as the raw multi-line message so the
    /// hover popover can render it via Text(_:) preserving line breaks.
    var commitMessageByID: [String: String] = [:]

    /// File paths inside each loaded commit diff. Mirrors `diffsByCommit`'s
    /// lifecycle (cleared on worktree change + head change). Empty array
    /// means the commit had no files (rare — e.g., merge-of-merge or
    /// empty cherry-pick).
    var commitFilePathsByID: [String: [String]] = [:]

    /// Change type (M/A/D/R) for each file in each loaded commit diff. Maps
    /// `[sha: [path: ChangeStatus]]`. Populated alongside `commitFilePathsByID`
    /// and cleared on the same lifecycle events. Enables the file-picker popup
    /// to display change-type badges in History mode.
    var commitFileChangeTypeByPath: [String: [String: ChangeStatus]] = [:]
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

    /// True while `.historyRefreshRequested` revalidates the first page with
    /// the existing `commits` kept on screen (stale-while-revalidate). Unlike
    /// `loading` — which the view turns into a full-surface placeholder when
    /// `commits` is empty — `refreshing` never clears the list; it only drives
    /// the header button spinner. Reset on refresh success / failure.
    var refreshing: Bool = false
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
  ///
  /// Explicitly `nonisolated` so the deinit does NOT route through the
  /// MainActor back-deploy shim (`swift_task_deinitOnExecutorMainActorBackDeploy`).
  /// Without this, releasing a `diffsByPath` / `diffsByCommit` dictionary
  /// holding cached entries — e.g. when `.historyRefreshRequested` clears
  /// the commit-diff cache — would crash in `TaskLocal::StopLookupScope::~`
  /// with `POINTER_BEING_FREED_WAS_NOT_ALLOCATED`. The class holds only an
  /// immutable `let`, so a nonisolated deinit is correct.
  nonisolated final class LoadedDiffDocument: Equatable, @unchecked Sendable {
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
    /// First page of a stale-while-revalidate History refresh. Replaces the
    /// `commits` array wholesale (vs `.historyPageSucceeded`, which appends
    /// for infinite scroll) so the list swaps atomically without flashing.
    case historyRefreshSucceeded([Commit], hasMore: Bool)
    /// A History refresh that failed. Keeps stale `commits` on screen when
    /// any exist; only promotes to the error surface when the list is empty.
    case historyRefreshFailed(GitError)
    case historyCommitTapped(sha: String)
    case commitDiffSucceededFor(sha: String, document: DiffDocument, filePaths: [String], changeTypes: [String: ChangeStatus])
    case commitDiffFailedFor(sha: String, error: GitError)
    case commitDiffTooLargeFor(sha: String, reason: TooLargeReason, copyCommand: String)
    /// Lazy fetch of the full commit message for the hover popover. Idempotent:
    /// the reducer no-ops when `commitMessageByID[sha]` already holds a value
    /// (including the empty-string sentinel that records a prior failure).
    case commitMessageRequested(sha: String)
    case commitMessageLoaded(sha: String, message: String)
    case commitMessageFailed(sha: String, error: GitError)
    /// File-row tap inside the History-mode drawer file picker. Today this
    /// is a no-op pending the JS bridge wiring for `scrollTo(file:)`. The
    /// reducer arm documents the deferred work inline.
    case commitFileScrollRequested(path: String)
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
    /// Per-sha cancellable so multiple parallel hover-fetches don't fight.
    /// `cancelInFlight: false` on the effect keeps each sha's load isolated.
    case commitMessage(sha: String)
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
        state.isRefreshingChanges = false
        // History side resets identically. `selectedTab` is NOT touched —
        // the user's tab preference persists across worktree switches.
        state.historyState = .init()
        state.presentedCommitSha = nil
        state.diffsByCommit = [:]
        state.commitMessageByID = [:]
        state.commitFilePathsByID = [:]
        state.commitFileChangeTypeByPath = [:]
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
        //
        // Stale-while-revalidate: when a list is already on screen, keep it
        // (and its `(n)` count) visible and only raise `isRefreshingChanges`
        // for the button spinner — replacing it with `.loading` would blank
        // the rows + count and flash. Fall back to the full `.loading`
        // placeholder only when there's nothing to keep showing (idle/error).
        guard let path = state.worktreePath, !path.isEmpty else { return .none }
        if case .loaded = state.changedFiles {
          state.isRefreshingChanges = true
        } else {
          state.changedFiles = .loading
        }
        return loadChangedFiles(at: path)

      case .changedFilesSucceeded(let files):
        state.changedFiles = .loaded(files)
        state.isRefreshingChanges = false
        return .none

      case .changedFilesFailed(let error):
        state.changedFiles = .error(error)
        state.isRefreshingChanges = false
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
        // Stale-while-revalidate: re-fetch the first page while keeping the
        // current commits on screen so the list never flashes to an empty /
        // loading placeholder. `refreshing` drives the button spinner; the
        // atomic swap lands in `.historyRefreshSucceeded`.
        //
        // Selection + per-commit caches (diff / message / file paths) are
        // deliberately preserved: a commit's content is sha-stable, so a
        // cached entry for a sha still present in the refreshed list stays
        // valid — and keeping `presentedCommitSha` avoids slamming the drawer
        // shut mid-refresh. When the list is empty (never-loaded / prior
        // error) fall back to the full loading placeholder via `loading`.
        guard let path = state.worktreePath, !path.isEmpty else { return .none }
        state.historyState.error = nil
        if state.historyState.commits.isEmpty {
          state.historyState.loading = true
        } else {
          state.historyState.refreshing = true
        }
        return loadHistoryFirstPage(at: path, limit: state.historyState.pageLimit)

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

      case .historyRefreshSucceeded(let commits, let hasMore):
        // Atomic swap of the whole list — the stale commits were kept on
        // screen during the refresh and are replaced in one render.
        state.historyState.commits = commits
        state.historyState.nextOffset = commits.count
        state.historyState.hasMore = hasMore
        state.historyState.loading = false
        state.historyState.refreshing = false
        state.historyState.error = nil
        return .none

      case .historyRefreshFailed(let error):
        // SWR failure: keep whatever commits are still shown. Only surface
        // the error when there's nothing to show, otherwise the view's error
        // branch would replace a still-valid list.
        state.historyState.loading = false
        state.historyState.refreshing = false
        if state.historyState.commits.isEmpty {
          state.historyState.error = error
        }
        return .none

      case .historyCommitTapped(let sha):
        // Guard FIRST: a missing worktree path is a no-op rather than a
        // selection mutation, so the inspector never visually highlights a
        // commit we can't load.
        guard let worktreePath = state.worktreePath, !worktreePath.isEmpty else {
          return .none
        }
        // Toggle: re-tapping the CURRENTLY-presented sha clears the
        // selection when the drawer is genuinely *showing* the diff —
        // `.loaded` (rendered) or `.tooLarge` (too-large placeholder).
        // `diffsByCommit[sha]` stays so a third tap re-presents from
        // cache instantly. Re-tap on `.error` deliberately falls through
        // so the in-drawer Retry button (which sends this same action)
        // re-issues the load instead of closing the drawer; `.loading`
        // similarly falls through and the cancel-in-flight handles it.
        if state.presentedCommitSha == sha {
          switch state.diffsByCommit[sha] {
          case .loaded, .tooLarge:
            state.presentedCommitSha = nil
            return .none
          case .error, .loading, .none:
            break
          }
        }
        // Cache hit on `.loaded` / `.tooLarge`: don't refetch. `.error`
        // falls through so the Retry button can re-issue the load
        // (FU-T14). `.loading` falls through too —
        // `.cancellable(cancelInFlight: true)` on `CancelID.commitDiff`
        // handles the in-flight overlap.
        state.presentedCommitSha = sha
        switch state.diffsByCommit[sha] {
        case .loaded, .tooLarge: return .none
        case .error, .loading, .none: break
        }
        state.diffsByCommit[sha] = .loading
        return loadCommitDiff(sha: sha, worktreePath: worktreePath)

      case .commitDiffSucceededFor(let sha, let document, let filePaths, let changeTypes):
        state.diffsByCommit[sha] = .loaded(LoadedDiffDocument(document))
        state.commitFilePathsByID[sha] = filePaths
        state.commitFileChangeTypeByPath[sha] = changeTypes
        return .none

      case .commitDiffFailedFor(let sha, let error):
        state.diffsByCommit[sha] = .error(error)
        return .none

      case .commitDiffTooLargeFor(let sha, let reason, let copyCommand):
        state.diffsByCommit[sha] = .tooLarge(reason: reason, copyCommand: copyCommand)
        return .none

      case .commitMessageRequested(let sha):
        // Idempotent: if already cached (including the "" sentinel for a
        // prior failure) or sha is empty, no-op. `cancelInFlight: false` on
        // the effect means we don't get free de-dup from cancellable IDs,
        // so the guard here is the actual de-dup.
        guard state.commitMessageByID[sha] == nil,
          let path = state.worktreePath, !path.isEmpty
        else { return .none }
        return loadCommitMessage(sha: sha, worktreePath: path)

      case .commitMessageLoaded(let sha, let message):
        state.commitMessageByID[sha] = message
        return .none

      case .commitMessageFailed(let sha, _):
        // Cache the empty string so we don't retry on every hover. The view
        // falls back to `commit.subject` when the cache holds "".
        state.commitMessageByID[sha] = ""
        return .none

      case .commitFileScrollRequested:
        // Pending: wire to DiffWebViewBridge.scrollTo(file:) so clicking a
        // file in the History-mode picker actually scrolls the renderer to
        // that file's anchor. Today the picker only displays the list; user
        // can still scroll the rendered patch manually.
        return .none

      case .headChangedForCurrentWorktree:
        // The commit list and any in-flight history fetch are stale by
        // definition. Drop the cache + per-commit cache + selection. Do
        // NOT touch `selectedTab` — user's tab choice survives HEAD
        // changes (same posture as `.worktreeSelected`).
        state.historyState = .init()
        state.presentedCommitSha = nil
        state.diffsByCommit = [:]
        state.commitMessageByID = [:]
        state.commitFilePathsByID = [:]
        state.commitFileChangeTypeByPath = [:]
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

  /// First-page reload for a stale-while-revalidate History refresh. Always
  /// fetches from offset 0 and reports via `.historyRefreshSucceeded`, which
  /// replaces the commit list wholesale (vs `loadHistoryPage` → append). Same
  /// `CancelID.historyPage` slot so a refresh supersedes any in-flight page.
  private func loadHistoryFirstPage(at worktreePath: String, limit: Int) -> Effect<Action> {
    .run { [gitService] send in
      do {
        let url = URL(fileURLWithPath: worktreePath)
        let cursor = LogPage.Cursor(offset: 0, limit: limit)
        let page = try await gitService.log(url, cursor)
        await send(.historyRefreshSucceeded(page.commits, hasMore: page.hasMore))
      } catch let error as GitError {
        await send(.historyRefreshFailed(error))
      } catch {
        await send(.historyRefreshFailed(.unparsable(context: "\(error)")))
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
        // `FileChange.id` is the post-image path (pre-image for deletions);
        // exactly what the drawer file-picker wants to render and dispatch
        // for scroll-to-file. See `GitModels.swift` FileChange docstring.
        let filePaths = unified.files.map(\.id)
        let changeTypes: [String: ChangeStatus] = Dictionary(
          uniqueKeysWithValues: unified.files.map { fileChange in
            (fileChange.id, Self.changeStatusFromFileChangeKind(fileChange.kind))
          }
        )
        let patch = Self.renderUnifiedDiffAsPatch(unified)
        let title = String(sha.prefix(7))
        let document = await MainActor.run { () -> DiffDocument in
          DiffDocument(files: [], title: title, fallbackPatch: patch)
        }
        await send(.commitDiffSucceededFor(sha: sha, document: document, filePaths: filePaths, changeTypes: changeTypes))
      } catch let error as GitError {
        await send(.commitDiffFailedFor(sha: sha, error: error))
      } catch {
        await send(.commitDiffFailedFor(sha: sha, error: .unparsable(context: "\(error)")))
      }
    }
    .cancellable(id: CancelID.commitDiff, cancelInFlight: true)
  }

  /// Maps a `FileChange.Kind` to a `ChangeStatus` for display in the
  /// file-picker popup. Handles the Unix diff semantics (added/deleted)
  /// plus Swift-specific statuses (renamed/copied/typeChanged).
  private nonisolated static func changeStatusFromFileChangeKind(_ kind: FileChange.Kind) -> ChangeStatus {
    switch kind {
    case .added: return .added
    case .deleted: return .deleted
    case .modified: return .modified
    case .renamed: return .renamed
    case .copied: return .added
    case .typeChanged: return .modified
    }
  }

  /// Lazy `git log -1 --format=%B <sha>` for the History-list hover popover.
  /// `cancelInFlight: false` lets parallel fetches for different SHAs run
  /// independently — when the cursor moves across rows, each row's hover
  /// kicks its own request and they all complete in parallel.
  private func loadCommitMessage(sha: String, worktreePath: String) -> Effect<Action> {
    .run { [gitService] send in
      do {
        let msg = try await gitService.commitMessage(sha, URL(fileURLWithPath: worktreePath))
        await send(.commitMessageLoaded(sha: sha, message: msg))
      } catch let error as GitError {
        await send(.commitMessageFailed(sha: sha, error: error))
      } catch {
        await send(.commitMessageFailed(sha: sha, error: .unparsable(context: "\(error)")))
      }
    }
    .cancellable(id: CancelID.commitMessage(sha: sha), cancelInFlight: false)
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

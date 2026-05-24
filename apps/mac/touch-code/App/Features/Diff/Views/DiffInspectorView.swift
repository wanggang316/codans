// MARK: M5
import ComposableArchitecture
import SwiftUI
import TouchCodeCore

/// Diff inspector column body. Hosts a segmented Changes / History tab
/// picker; routes the body to either the changed-files list (M5 default)
/// or the commit-history list (T13). Width is fixed at 280 pt by the
/// inspector mount in `ContentView`.
struct DiffInspectorView: View {
  @Bindable var store: StoreOf<DiffFeature>
  /// Invoked when the user clicks the header's close button. Wired by the
  /// mount site (`WorktreeDetailView`) to force the inspector hidden — the
  /// symmetric counterpart to FU-T10's "View all" open path, bypassing the
  /// 3-tier Git Viewer resolution that `.diffInspectorToggledForCurrentWorktree`
  /// would otherwise run.
  let onClose: () -> Void

  var body: some View {
    VStack(spacing: 0) {
      tabPicker
      Divider()
      header
      Divider()
      content
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    .background(Color(nsColor: .windowBackgroundColor))
  }

  // MARK: - Tab picker

  @ViewBuilder
  private var tabPicker: some View {
    // `DiffFeature` is not `BindableAction`-conformant, so `$store.selectedTab`
    // can't bridge writes straight back into state. A manual `Binding` that
    // forwards through `.tabSelected` keeps the reducer the sole owner of
    // `selectedTab`, matching the pattern used by `BranchSwitcherView` and
    // `DiffStylePicker`.
    let binding = Binding<DiffFeature.DiffTab>(
      get: { store.selectedTab },
      set: { newValue in
        guard newValue != store.selectedTab else { return }
        store.send(.tabSelected(newValue))
      }
    )
    Picker("Inspector tab", selection: binding) {
      Text("Changes").tag(DiffFeature.DiffTab.changes)
      Text("History").tag(DiffFeature.DiffTab.history)
    }
    .pickerStyle(.segmented)
    .labelsHidden()
    .padding(.horizontal, 12)
    .padding(.vertical, 6)
    .accessibilityIdentifier("diff_inspector.tab_picker")
  }

  // MARK: - Header

  private var header: some View {
    HStack(spacing: 8) {
      Text(headerTitle)
        .font(.headline)
      Spacer()
      Button {
        handleRefresh()
      } label: {
        Image(systemName: "arrow.clockwise")
      }
      .buttonStyle(.borderless)
      .disabled(isRefreshing)
      .help(refreshHelp)
      .accessibilityLabel(refreshHelp)

      Button {
        onClose()
      } label: {
        Image(systemName: "xmark")
      }
      .buttonStyle(.borderless)
      .help("Close inspector")
      .accessibilityLabel("Close inspector")
      .accessibilityIdentifier("diff_inspector.close_button")
    }
    .padding(.horizontal, 12)
    .padding(.vertical, 8)
  }

  private var headerTitle: String {
    switch store.selectedTab {
    case .changes:
      if case .loaded(let files) = store.changedFiles { return "Changes (\(files.count))" }
      return "Changes"
    case .history:
      // History is paginated; "loaded so far" isn't a meaningful signal.
      return "History"
    }
  }

  private var isRefreshing: Bool {
    switch store.selectedTab {
    case .changes:
      if case .loading = store.changedFiles { return true }
      return false
    case .history:
      return store.historyState.loading
    }
  }

  private var refreshHelp: String {
    switch store.selectedTab {
    case .changes: return "Refresh changed files"
    case .history: return "Refresh history"
    }
  }

  private func handleRefresh() {
    switch store.selectedTab {
    case .changes:
      store.send(.refreshRequested)
    case .history:
      // Atomic refresh — the reducer resets cache + selection and re-fires
      // the first-page load in a single arm. See FU-T12.
      store.send(.historyRefreshRequested)
    }
  }

  // MARK: - Content

  @ViewBuilder
  private var content: some View {
    switch store.selectedTab {
    case .changes:
      changesBody
    case .history:
      historyBody
    }
  }

  @ViewBuilder
  private var changesBody: some View {
    switch store.changedFiles {
    case .idle:
      placeholder("No worktree selected")
    case .loading:
      ProgressView()
        .controlSize(.small)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    case .loaded(let files):
      if files.isEmpty {
        placeholder("No changes")
      } else {
        fileList(files)
      }
    case .error(let error):
      errorBlock(error)
    }
  }

  @ViewBuilder
  private var historyBody: some View {
    DiffHistoryListView(store: store)
  }

  @ViewBuilder
  private func fileList(_ files: [ChangedFile]) -> some View {
    ScrollView {
      LazyVStack(alignment: .leading, spacing: 0) {
        ForEach(files) { file in
          DiffFileRow(
            file: file,
            isPresented: store.presentedFilePath == file.id,
            onOpenTap: { store.send(.fileRowTapped(path: file.id)) },
            onChevronTap: {
              if store.presentedFilePath == file.id {
                store.send(.drawerCloseRequested)
              } else {
                store.send(.fileRowTapped(path: file.id))
              }
            }
          )
          Divider()
        }
      }
    }
    .accessibilityIdentifier("diff_inspector.changes_list")
  }

  @ViewBuilder
  private func placeholder(_ text: String) -> some View {
    VStack {
      Text(text)
        .font(.callout)
        .foregroundStyle(.secondary)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
  }

  @ViewBuilder
  private func errorBlock(_ error: GitError) -> some View {
    VStack(spacing: 10) {
      Image(systemName: "exclamationmark.triangle")
        .foregroundStyle(.orange)
        .font(.title3)
      Text(Self.errorMessage(error))
        .font(.callout)
        .foregroundStyle(.secondary)
        .multilineTextAlignment(.center)
        .padding(.horizontal, 12)
      Button("Retry") {
        store.send(.refreshRequested)
      }
      .controlSize(.small)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
  }

  /// Collapse a `GitError` to a single-line user-facing message. Mirrors
  /// the verb-prefixed format the status bar uses elsewhere in the app
  /// (e.g. `RootFeature.runScriptErrorMessage`).
  private static func errorMessage(_ error: GitError) -> String {
    switch error {
    case .notARepo: return "Not a git repository"
    case .gitMissing: return "git not found"
    case .outputTooLarge: return "Output too large"
    case .diffTooLarge: return "Diff too large"
    case .timedOut: return "git timed out"
    case .exec(_, let stderr):
      let firstLine = stderr.split(separator: "\n", maxSplits: 1).first.map(String.init) ?? ""
      let trimmed = firstLine.trimmingCharacters(in: .whitespacesAndNewlines)
      return trimmed.isEmpty ? "git failed" : trimmed
    case .invalidInput(let detail): return detail
    case .unparsable: return "Unrecognised diff format"
    case .malformedRemoteURL: return "Malformed remote URL"
    }
  }
}

// MARK: M5
import AppKit
import ComposableArchitecture
import SwiftUI
import TouchCodeCore

/// Diff inspector column body. Hosts a custom full-width Changes /
/// History tab bar (macOS 26 Tahoe sidebar-tab style); routes the body
/// to either the changed-files list (M5 default) or the commit-history
/// list (T13). Width is fixed at 280 pt by the inspector mount in
/// `ContentView`. The header close button is gone in favour of the
/// toolbar Git Viewer toggle (Phase E), which now owns the open/close
/// affordance from a more discoverable location.
struct DiffInspectorView: View {
  @Bindable var store: StoreOf<DiffFeature>

  var body: some View {
    VStack(spacing: 0) {
      tabPicker
      Divider()
      header
      Divider()
      content
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    // No hand-rolled background: the SwiftUI `.inspector(...)` modifier
    // host applies the system sidebar material and extends it behind the
    // toolbar automatically, the same way NavigationSplitView's leading
    // column does. Painting a VisualEffectBackground on top fights with
    // the system surface and produces the visible split this column had
    // before adopting `.inspector`.
  }

  // MARK: - Tab picker

  /// Sidebar-tab style: a single rounded container holding two segments.
  /// The selected segment renders as a filled accent capsule that
  /// visually overlays the divider between segments; the unselected
  /// segment is borderless. Matches the macOS 26 Tahoe icon-only
  /// segmented control idiom.
  private var tabPicker: some View {
    ZStack {
      Capsule()
        .fill(Color(nsColor: .controlColor).opacity(0.55))
      Capsule()
        .strokeBorder(Color.primary.opacity(0.12), lineWidth: 0.5)
      HStack(spacing: 0) {
        tabSegment(.changes, systemImage: "doc.text", label: "Changes")
        tabSegment(.history, systemImage: "clock.arrow.circlepath", label: "History")
      }
    }
    .frame(height: 32)
    .padding(.horizontal, 12)
    .padding(.vertical, 8)
    .accessibilityIdentifier("diff_inspector.tab_picker")
  }

  @ViewBuilder
  private func tabSegment(
    _ tab: DiffFeature.DiffTab,
    systemImage: String,
    label: String
  ) -> some View {
    let isSelected = store.selectedTab == tab
    Button {
      if !isSelected {
        store.send(.tabSelected(tab))
      }
    } label: {
      ZStack {
        if isSelected {
          Capsule()
            .fill(Color.accentColor)
            .padding(2)
        }
        Image(systemName: systemImage)
          .font(.body)
          .foregroundStyle(isSelected ? Color.white : Color.secondary)
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity)
      .contentShape(.rect)
    }
    .buttonStyle(.plain)
    .help(label)
    .accessibilityLabel(label)
    .accessibilityAddTraits(isSelected ? .isSelected : [])
  }

  // MARK: - Header

  private var header: some View {
    HStack(spacing: 6) {
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

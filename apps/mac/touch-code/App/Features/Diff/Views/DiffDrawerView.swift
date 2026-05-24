// MARK: M6
import AppKit
import ComposableArchitecture
import SwiftUI
import TouchCodeCore

/// Drawer that renders one file's diff. Mounted by `WorktreeDetailView`
/// as an overlay on `terminalRegion`; covers the entire terminal area
/// edge-to-edge while `presentedFilePath != nil`.
struct DiffDrawerView: View {
  @Bindable var store: StoreOf<DiffFeature>
  @Environment(\.colorScheme) private var colorScheme

  var body: some View {
    VStack(spacing: 0) {
      header
      Divider()
      content
    }
    .background(Color(nsColor: .windowBackgroundColor))
  }

  // MARK: - Header

  private var header: some View {
    HStack(spacing: 12) {
      Text(titleText)
        .font(.system(.callout, design: .monospaced))
        .lineLimit(1)
        .truncationMode(.head)
        .frame(maxWidth: .infinity, alignment: .leading)
        .help(titleText)
        .accessibilityIdentifier("diff_drawer.title_text")
      DiffStylePicker(store: store)
      Button {
        store.send(.drawerCloseRequested)
      } label: {
        Image(systemName: "xmark")
      }
      .buttonStyle(.borderless)
      .accessibilityLabel("Close diff")
      .keyboardShortcut(.cancelAction)
    }
    .padding(.horizontal, 12)
    .padding(.vertical, 8)
  }

  /// Title rendered in the drawer header. Routes on the active tab:
  ///   - Changes: the presented file path (already monospaced-friendly).
  ///   - History: `<short-sha> · <subject>` where the short SHA is the
  ///     first 7 characters of the full SHA (matches the UT-BSH-DV-002
  ///     regex `^[0-9a-f]{7,12}\s+·\s+.+$`). Falls back to the sha alone
  ///     when the commits cache doesn't carry the selected sha (defensive
  ///     for a future deep-link path; not reachable in normal flow).
  private var titleText: String {
    switch store.selectedTab {
    case .changes:
      return store.presentedFilePath ?? ""
    case .history:
      guard let sha = store.presentedCommitSha else { return "" }
      let shortSha = String(sha.prefix(7))
      if let commit = store.historyState.commits.first(where: { $0.id == sha }) {
        return "\(shortSha) · \(commit.subject)"
      } else {
        return shortSha
      }
    }
  }

  // MARK: - Content

  @ViewBuilder
  private var content: some View {
    switch store.selectedTab {
    case .changes:
      changesContent
    case .history:
      historyContent
    }
  }

  @ViewBuilder
  private var changesContent: some View {
    if let path = store.presentedFilePath {
      switch store.diffsByPath[path] {
      case .none, .loading?:
        ProgressView()
          .controlSize(.small)
          .frame(maxWidth: .infinity, maxHeight: .infinity)
      case .loaded(let wrapper)?:
        DiffRendererView(document: wrapper.document, configuration: makeConfig())
      case .error(let error)?:
        errorBlock(path: path, error: error)
      case .tooLarge(let reason, let copyCommand)?:
        tooLargeBlock(reason: reason, copyCommand: copyCommand)
      }
    } else {
      // Drawer should not have rendered without a presented path; render
      // an empty surface as a safety fallback rather than a placeholder
      // string the user is unlikely to ever see.
      Color.clear
    }
  }

  @ViewBuilder
  private var historyContent: some View {
    if let sha = store.presentedCommitSha {
      switch store.diffsByCommit[sha] {
      case .none, .loading?:
        ProgressView()
          .controlSize(.small)
          .frame(maxWidth: .infinity, maxHeight: .infinity)
      case .loaded(let wrapper)?:
        DiffRendererView(document: wrapper.document, configuration: makeConfig())
      case .error(let error)?:
        commitErrorBlock(sha: sha, error: error)
      case .tooLarge(let reason, let copyCommand)?:
        // `tooLargeBlock` is path-agnostic — reuse for the commit-diff path.
        tooLargeBlock(reason: reason, copyCommand: copyCommand)
      }
    } else {
      Color.clear
    }
  }

  private func makeConfig() -> DiffConfiguration {
    DiffConfiguration(
      appearance: colorScheme == .dark ? .dark : .light,
      style: store.state.style
    )
  }

  // MARK: - Error / TooLarge blocks

  @ViewBuilder
  private func errorBlock(path: String, error: GitError) -> some View {
    VStack(spacing: 10) {
      Image(systemName: "exclamationmark.triangle")
        .font(.title2)
        .foregroundStyle(.orange)
      Text(Self.errorMessage(error))
        .font(.callout)
        .foregroundStyle(.secondary)
        .multilineTextAlignment(.center)
        .padding(.horizontal, 16)
      Button("Retry") {
        store.send(.fileRowTapped(path: path))
      }
      .controlSize(.small)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
  }

  /// History-side error block. Distinct from `errorBlock(path:error:)`
  /// because the retry actions differ — Changes re-dispatches
  /// `.fileRowTapped(path:)`; History re-dispatches
  /// `.historyCommitTapped(sha:subject:)`. Subject is recovered from the
  /// commits cache; if the cache no longer carries the selected sha (a
  /// state that shouldn't occur in normal flow), the retry falls back to
  /// an empty subject — the reducer doesn't store `subject` anyway.
  @ViewBuilder
  private func commitErrorBlock(sha: String, error: GitError) -> some View {
    VStack(spacing: 10) {
      Image(systemName: "exclamationmark.triangle")
        .font(.title2)
        .foregroundStyle(.orange)
        .accessibilityHidden(true)
      Text(Self.errorMessage(error))
        .font(.callout)
        .foregroundStyle(.secondary)
        .multilineTextAlignment(.center)
        .padding(.horizontal, 16)
      Button("Retry") {
        let subject = store.historyState.commits.first(where: { $0.id == sha })?.subject ?? ""
        store.send(.historyCommitTapped(sha: sha, subject: subject))
      }
      .controlSize(.small)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
  }

  @ViewBuilder
  private func tooLargeBlock(
    reason: DiffFeature.TooLargeReason, copyCommand: String
  ) -> some View {
    VStack(spacing: 12) {
      Image(systemName: "doc.on.doc")
        .font(.title2)
        .foregroundStyle(.secondary)
      Text("Diff too large to render")
        .font(.headline)
      Text(Self.tooLargeReason(reason))
        .font(.callout)
        .foregroundStyle(.secondary)
        .multilineTextAlignment(.center)
        .padding(.horizontal, 16)
      Button("Copy command") {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(copyCommand, forType: .string)
      }
      .controlSize(.small)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
  }

  private static func tooLargeReason(_ reason: DiffFeature.TooLargeReason) -> String {
    switch reason {
    case .byteCount(let n): return "File is \(n.formatted()) bytes"
    case .lineCount(let n): return "File has \(n.formatted()) lines"
    case .binary: return "File is binary"
    }
  }

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

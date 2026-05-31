// MARK: M6
import AppKit
import ComposableArchitecture
import SwiftUI
import TouchCodeCore

/// Panel that renders one file's diff. Mounted by `WorktreeDetailView`
/// as an overlay on `terminalRegion`; covers the entire terminal area
/// edge-to-edge while `presentedFilePath != nil`.
struct DiffPanelView: View {
  @Bindable var store: StoreOf<DiffFeature>
  @Environment(\.colorScheme) private var colorScheme
  /// Drives the changed-files picker popover. Local view state — the
  /// popover lives entirely inside the panel header; the store doesn't
  /// need to know about it.
  @State private var showFilePicker = false

  var body: some View {
    VStack(spacing: 0) {
      header
      Divider()
      content
    }
    .background(themeBackground)
  }

  /// Panel background tracks Ghostty's terminal theme so the diff surface
  /// blends with the surrounding panes instead of clashing on
  /// `.windowBackgroundColor`. Falls back to `.underPageBackgroundColor`
  /// during runtime bring-up (singleton not yet initialised) — matches
  /// `LazyPaneHost`'s precedent.
  ///
  /// Caveat: the runtime singleton's `backgroundColor()` is evaluated each
  /// render, but the view doesn't observe the runtime for theme changes.
  /// A live theme swap won't refresh until the panel re-renders for some
  /// other reason. Acceptable for now (theme changes are rare); a future
  /// pass can subscribe to a runtime publisher.
  private var themeBackground: Color {
    let color = GhosttyRuntime.shared?.backgroundColor() ?? .underPageBackgroundColor
    return Color(nsColor: color)
  }

  // MARK: - Header

  private var header: some View {
    HStack(spacing: 8) {
      Text(titleText)
        .font(.system(.callout, design: .monospaced))
        .lineLimit(1)
        .truncationMode(.head)
        .frame(maxWidth: .infinity, alignment: .leading)
        .help(titleText)
        .accessibilityIdentifier("diff_panel.title_text")
      if shouldShowFilePicker {
        Button {
          showFilePicker.toggle()
        } label: {
          Image(systemName: "list.bullet.rectangle")
        }
        .buttonStyle(.borderless)
        .help("Show changed files")
        .accessibilityLabel("Show changed files")
        .accessibilityIdentifier("diff_panel.file_picker_button")
        .popover(isPresented: $showFilePicker, arrowEdge: .top) {
          filePickerContent
        }
      }
      DiffStylePicker(store: store)
      Button {
        store.send(.panelCloseRequested)
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

  /// File picker is only enabled in Changes mode, where it picks the file
  /// that fills the panel. Tapping a row dispatches `.fileRowTapped` and
  /// the panel re-renders with that file's diff.
  ///
  /// In History mode the row would need to scroll the rendered commit
  /// diff to the matching file section, but the vendored YiTong renderer
  /// doesn't expose stable file anchors (no data-file / id attributes)
  /// and reverse-engineering its scrollable container has been brittle.
  /// Hidden until the renderer ships a real `scrollToFile` API.
  ///
  /// Empty file lists also hide the button — no point opening a popover
  /// with zero rows.
  private var shouldShowFilePicker: Bool {
    switch store.selectedTab {
    case .changes:
      if case .loaded(let files) = store.changedFiles, !files.isEmpty {
        return true
      }
      return false
    case .history:
      return false
    }
  }

  @ViewBuilder
  private var filePickerContent: some View {
    switch store.selectedTab {
    case .changes:
      if case .loaded(let files) = store.changedFiles {
        filePickerList(
          items: files.map(\.id),
          currentlyPresented: store.presentedFilePath,
          onTap: { path in
            store.send(.fileRowTapped(path: path))
            showFilePicker = false
          }
        )
      } else {
        Text("No changes")
          .foregroundStyle(.secondary)
          .padding(12)
      }
    case .history:
      if let sha = store.presentedCommitSha,
        let paths = store.commitFilePathsByID[sha]
      {
        filePickerList(
          items: paths,
          currentlyPresented: nil,
          onTap: { path in
            // Tell the live DiffWebView to scroll to this file. The
            // reducer action is also dispatched for tests / future
            // bookkeeping, but the actual scroll happens via this
            // notification — the reducer can't reach a WKWebView
            // directly. See `DiffWebViewCoordinator.scrollToFile`.
            NotificationCenter.default.post(
              name: .diffScrollToFileRequested,
              object: nil,
              userInfo: ["path": path]
            )
            store.send(.commitFileScrollRequested(path: path))
            showFilePicker = false
          }
        )
      } else {
        Text("No files")
          .foregroundStyle(.secondary)
          .padding(12)
      }
    }
  }

  /// Shared file-picker list renderer. In Changes mode, shows checkmark +
  /// file path. In History mode, omits checkmark and shows change-type
  /// badge (M/A/D/R) next to the path. `currentlyPresented == nil` skips
  /// the checkmark column entirely, keeping the visual surface honest.
  ///
  /// Each row has an explicit `.frame(height: rowHeight)` so the
  /// container's computed height matches the actual content exactly —
  /// without this the row's intrinsic height varies a few pt between
  /// items, accumulates into a bottom whitespace strip, and looks
  /// asymmetric vs the top padding.
  private static let pickerRowHeight: CGFloat = 32
  private static let pickerVerticalPadding: CGFloat = 4

  private func filePickerList(
    items: [String],
    currentlyPresented: String?,
    onTap: @escaping (String) -> Void
  ) -> some View {
    let contentHeight =
      CGFloat(items.count) * Self.pickerRowHeight + Self.pickerVerticalPadding * 2
    return ScrollView {
      LazyVStack(alignment: .leading, spacing: 0) {
        ForEach(items, id: \.self) { (path: String) in
          filePickerRow(
            path: path,
            isCurrent: currentlyPresented == path,
            showsCheckmarkColumn: currentlyPresented != nil,
            onTap: onTap
          )
        }
      }
      .padding(.vertical, Self.pickerVerticalPadding)
    }
    .frame(width: 480, height: min(contentHeight, 360))
  }

  @ViewBuilder
  private func filePickerRow(
    path: String,
    isCurrent: Bool,
    showsCheckmarkColumn: Bool,
    onTap: @escaping (String) -> Void
  ) -> some View {
    Button {
      onTap(path)
    } label: {
      HStack(spacing: 10) {
        if showsCheckmarkColumn {
          checkmarkBadge(isCurrent: isCurrent)
        } else {
          changeTypeBadge(path: path)
        }
        Text(path)
          .font(.system(.callout, design: .monospaced))
          .lineLimit(1)
          .truncationMode(.middle)
          .frame(maxWidth: .infinity, alignment: .leading)
          .foregroundStyle(.primary)
      }
      .padding(.horizontal, 16)
      .frame(height: Self.pickerRowHeight)
      .contentShape(.rect)
    }
    .buttonStyle(.plain)
    .background(isCurrent ? Color.accentColor.opacity(0.12) : Color.clear)
    .accessibilityIdentifier("diff_panel.file_picker_row.\(path)")
  }

  @ViewBuilder
  private func checkmarkBadge(isCurrent: Bool) -> some View {
    if isCurrent {
      Image(systemName: "checkmark.circle.fill")
        .foregroundStyle(Color.accentColor)
        .frame(width: 18)
        .accessibilityHidden(true)
    } else {
      Image(systemName: "circle")
        .foregroundStyle(.secondary)
        .opacity(0.4)
        .frame(width: 18)
        .accessibilityHidden(true)
    }
  }

  /// Badge showing the change type for History-mode files. Looks up the
  /// status from `store.commitFileChangeTypeByPath[sha][path]` if available;
  /// falls back to an empty space if the path isn't found. This only
  /// renders in History mode where the change type is known.
  private func changeTypeBadge(path: String) -> some View {
    let statusChar: String
    if let sha = store.presentedCommitSha,
      let changeTypes = store.commitFileChangeTypeByPath[sha],
      let status = changeTypes[path]
    {
      switch status {
      case .modified: statusChar = "M"
      case .added: statusChar = "A"
      case .deleted: statusChar = "D"
      case .renamed: statusChar = "R"
      }
    } else {
      statusChar = ""
    }

    return Text(statusChar)
      .font(.system(.footnote, design: .monospaced))
      .fontWeight(.bold)
      .foregroundStyle(colorForChangeType(statusChar))
      .frame(width: 18, alignment: .center)
      .accessibilityHidden(true)
  }

  private func colorForChangeType(_ char: String) -> Color {
    switch char {
    case "M": return .orange
    case "A": return .green
    case "D": return .red
    case "R": return .blue
    default: return .secondary
    }
  }

  /// Title rendered in the panel header. Routes on the active tab:
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
      let state = store.diffsByPath[path]
      switch state {
      case .error(let error)?:
        errorBlock(path: path, error: error)
      case .tooLarge(let reason, let copyCommand)?:
        tooLargeBlock(reason: reason, copyCommand: copyCommand)
      default:
        // `.none` / `.loading` / `.loaded` all flow through a single
        // continuously-mounted surface so one spinner spans the whole
        // fetch→render lifecycle. Routing each state to its own branch
        // would give them distinct view identities and tear the spinner
        // down between phases — the visible two-flash gap we avoid here.
        DiffLoadingContent(
          id: path,
          document: state?.loadedDocument,
          configuration: makeConfig(),
          background: themeBackground
        )
      }
    } else {
      // Panel should not have rendered without a presented path; render
      // an empty surface as a safety fallback rather than a placeholder
      // string the user is unlikely to ever see.
      Color.clear
    }
  }

  @ViewBuilder
  private var historyContent: some View {
    if let sha = store.presentedCommitSha {
      let state = store.diffsByCommit[sha]
      switch state {
      case .error(let error)?:
        commitErrorBlock(sha: sha, error: error)
      case .tooLarge(let reason, let copyCommand)?:
        // `tooLargeBlock` is path-agnostic — reuse for the commit-diff path.
        tooLargeBlock(reason: reason, copyCommand: copyCommand)
      default:
        DiffLoadingContent(
          id: sha,
          document: state?.loadedDocument,
          configuration: makeConfig(),
          background: themeBackground
        )
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
        .accessibilityHidden(true)
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
  /// `.historyCommitTapped(sha:)`.
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
        store.send(.historyCommitTapped(sha: sha))
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
        .accessibilityHidden(true)
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

extension DiffFeature.DiffEntryState {
  /// The rendered document, or `nil` while the diff is still being fetched
  /// (`.loading` / not cached yet). Lets `DiffLoadingContent` treat fetch
  /// and render as one continuous loading phase.
  fileprivate var loadedDocument: DiffDocument? {
    if case .loaded(let wrapper) = self { return wrapper.document }
    return nil
  }
}

/// One continuous loading surface spanning both diff phases: the `git diff`
/// fetch (`document == nil`) and the WebView render that follows. A single
/// spinner stays mounted across the whole lifecycle and is torn down only
/// once the renderer paints, so the user never sees the two-flash gap of a
/// fetch spinner handing off to a separate render spinner.
///
/// Mechanics:
///   - While `document == nil` the renderer isn't mounted; the spinner
///     covers the fetch.
///   - Once the document loads, `DiffRendererView` mounts *underneath* the
///     same spinner and boots the vendored renderer bundle (~9.7 MB); the
///     spinner hides only when the renderer reports `renderStateChanged:
///     rendered` (surfaced as `DiffEvent.didRender`).
///   - The spinner is revealed after a short delay so a fully-cached,
///     fast-rendering diff never flashes a spinner at all.
private struct DiffLoadingContent: View {
  /// Cheap identity (file path or commit sha). A change marks a new
  /// document as in-flight without an O(bytes) `DiffDocument` comparison.
  let id: String
  /// `nil` while the diff is still being fetched; non-nil once loaded.
  let document: DiffDocument?
  let configuration: DiffConfiguration
  /// Opaque cover painted under the spinner so the WebView's cold-start
  /// (and any stale prior diff) stays hidden until the new diff paints.
  let background: Color

  /// Flips true when the renderer paints `document`. Reset when `id`
  /// changes so a newly-selected diff shows the spinner again.
  @State private var rendered = false
  @State private var showSpinner = false

  /// Loading until the document has both loaded *and* painted.
  private var isLoading: Bool { document == nil || !rendered }

  var body: some View {
    ZStack {
      if let document {
        DiffRendererView(document: document, configuration: configuration) { event in
          switch event {
          case .didRender:
            rendered = true
          case .didFail(let code, _):
            // The renderer's in-progress "loading" state arrives as
            // `.didFail(code: "render_state")` (see `DiffWebViewBridge`);
            // that is benign and must NOT clear the spinner. Any other
            // failure is terminal — stop the spinner so we don't hang.
            if code != "render_state" { rendered = true }
          default:
            break
          }
        }
      }
      if showSpinner {
        ZStack {
          background
          ProgressView().controlSize(.small)
        }
      }
    }
    .onChange(of: id) { _, _ in rendered = false }
    .task(id: LoadToken(id: id, hasDocument: document != nil, rendered: rendered)) {
      guard isLoading else {
        showSpinner = false
        return
      }
      // Delay the reveal so a fully-cached, fast-rendering diff never
      // flashes a spinner; slow fetches / cold renders always outlast it.
      try? await Task.sleep(for: .milliseconds(120))
      guard !Task.isCancelled else { return }
      showSpinner = true
      // Safety net measured from this fetch/render attempt: never spin
      // forever if the renderer goes silent after the document loads.
      try? await Task.sleep(for: .seconds(15))
      guard !Task.isCancelled else { return }
      rendered = true
    }
  }

  /// `.task(id:)` key: restarts the reveal/timeout cycle when a new diff is
  /// selected (`id`), when the fetch completes (`hasDocument`), or when the
  /// render finishes (`rendered`). `hasDocument` is part of the key so the
  /// safety timeout re-arms from the moment the document loads, not from
  /// the start of the fetch.
  private struct LoadToken: Equatable {
    let id: String
    let hasDocument: Bool
    let rendered: Bool
  }
}

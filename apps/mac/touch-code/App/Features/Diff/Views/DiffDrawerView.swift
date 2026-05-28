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
  /// Drives the changed-files picker popover. Local view state — the
  /// popover lives entirely inside the drawer header; the store doesn't
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

  /// Drawer background tracks Ghostty's terminal theme so the diff surface
  /// blends with the surrounding panes instead of clashing on
  /// `.windowBackgroundColor`. Falls back to `.underPageBackgroundColor`
  /// during runtime bring-up (singleton not yet initialised) — matches
  /// `LazyPaneHost`'s precedent.
  ///
  /// Caveat: the runtime singleton's `backgroundColor()` is evaluated each
  /// render, but the view doesn't observe the runtime for theme changes.
  /// A live theme swap won't refresh until the drawer re-renders for some
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
        .accessibilityIdentifier("diff_drawer.title_text")
      if shouldShowFilePicker {
        Button {
          showFilePicker.toggle()
        } label: {
          Image(systemName: "list.bullet.rectangle")
        }
        .buttonStyle(.borderless)
        .help("Show changed files")
        .accessibilityLabel("Show changed files")
        .accessibilityIdentifier("diff_drawer.file_picker_button")
        .popover(isPresented: $showFilePicker, arrowEdge: .top) {
          filePickerContent
        }
      }
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

  /// File picker is enabled for both Changes and History modes:
  ///   - Changes: shows the live `changedFiles` list (`isPresented`
  ///     checkmark mirrors `presentedFilePath`).
  ///   - History: shows the file paths extracted from the loaded commit
  ///     diff (no checkmark — there's no "current file" concept inside a
  ///     single commit). Tap dispatches `.commitFileScrollRequested`,
  ///     today a no-op pending JS bridge wiring.
  ///
  /// Empty file lists hide the button — no point opening a popover with
  /// zero rows.
  private var shouldShowFilePicker: Bool {
    switch store.selectedTab {
    case .changes:
      if case .loaded(let files) = store.changedFiles, !files.isEmpty {
        return true
      }
      return false
    case .history:
      guard let sha = store.presentedCommitSha,
        let paths = store.commitFilePathsByID[sha],
        !paths.isEmpty
      else { return false }
      return true
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
  /// Uses `.simultaneousGesture` instead of `Button` so the popover
  /// auto-dismiss-on-click doesn't swallow the tap on the row (a known
  /// SwiftUI popover quirk). The gesture runs alongside the popover
  /// dismissal so both fire on the same click.
  private func filePickerList(
    items: [String],
    currentlyPresented: String?,
    onTap: @escaping (String) -> Void
  ) -> some View {
    ScrollView {
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
      .padding(.vertical, 6)
    }
    .frame(width: 480, height: min(CGFloat(items.count) * 34 + 16, 360))
  }

  @ViewBuilder
  private func filePickerRow(
    path: String,
    isCurrent: Bool,
    showsCheckmarkColumn: Bool,
    onTap: @escaping (String) -> Void
  ) -> some View {
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
    }
    .padding(.horizontal, 16)
    .padding(.vertical, 8)
    .contentShape(.rect)
    .background(isCurrent ? Color.accentColor.opacity(0.12) : Color.clear)
    .simultaneousGesture(
      TapGesture().onEnded {
        onTap(path)
      }
    )
    .accessibilityAddTraits(.isButton)
    .accessibilityIdentifier("diff_drawer.file_picker_row.\(path)")
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

import CodansCore
import ComposableArchitecture
import DiffViewKit
import SwiftUI

struct DiffPanelView: View {
  @Bindable var store: StoreOf<DiffFeature>
  @Environment(\.colorScheme) private var colorScheme
  /// Set once the renderer has drawn a document and kept while it swaps to the next one, so a
  /// stale or blank renderer never flashes between two screens.
  @State private var showingDocument = false
  /// The last notice, kept on screen while the next file's document is still being drawn.
  @State private var heldNotice: String?
  /// Loading indicators appear only when loading is slow, not on every file switch.
  @State private var slowLoading = false

  private var outgoing: Bool { store.state.scope == .outgoing }
  private var comparisonIsEmpty: Bool { store.snapshot?.files.isEmpty == true }
  private var documentVisible: Bool {
    store.document != nil && showingDocument && store.error == nil && !comparisonIsEmpty
  }
  private var loadingKey: Int? { store.contentLoading || store.snapshot == nil ? store.contentRequest : nil }
  private var selectedFile: GitComparisonFile? {
    store.snapshot?.files.first { $0.id == store.selectedFileID }
  }
  var body: some View {
    NavigationSplitView(
      columnVisibility: Binding(
        get: { store.sidebarVisible ? .all : .detailOnly },
        set: { visibility in
          if (visibility != .detailOnly) != store.sidebarVisible {
            _ = withAnimation { store.send(.toggleSidebar) }
          }
        }
      )
    ) {
      DiffFileSidebar(store: store)
        .navigationSplitViewColumnWidth(min: 220, ideal: 260, max: 320)
    } detail: {
      VStack(spacing: 0) {
        fileHeader
        Divider()
        content
        if let message = store.editorMessage {
          Divider()
          Text(message).font(.caption).foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading).padding(8)
        }
      }
      .frame(minWidth: 320, maxWidth: .infinity, maxHeight: .infinity)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .toolbar { DiffWindowToolbar(store: store) }
    .accessibilityIdentifier("diff-panel")
  }

  private var fileHeader: some View {
    HStack(spacing: 8) {
      Text(selectedFile?.path ?? (outgoing ? "Outgoing" : "Uncommitted"))
        .font(.system(size: 12)).lineLimit(1).truncationMode(.middle)
        .help(selectedFile?.path ?? "Select a file")
      Spacer(minLength: 8)
      if slowLoading && store.contentLoading {
        ProgressView().controlSize(.mini).accessibilityLabel("Loading file")
      }
      if let added = selectedFile?.additions, let removed = selectedFile?.deletions {
        Text("+\(added)").foregroundStyle(ThemeGit.added)
        Text("−\(removed)").foregroundStyle(ThemeGit.removed)
      }
    }
    .font(.system(size: 11).monospacedDigit())
    .padding(.horizontal, 12)
    .frame(height: 32)
    .background(Color(nsColor: .controlBackgroundColor))
  }

  private var content: some View {
    ZStack {
      // The native window owns navigation and presentation controls; WebKit only renders code.
      DiffView(
        document: store.document ?? DiffDocument(id: "empty", path: "empty.txt", oldText: "", newText: ""),
        options: DiffOptions(layout: store.layout, theme: colorScheme == .dark ? "dark" : "light", chrome: "none")
      ) { event in
        guard event.documentID == nil || event.documentID == store.document?.id else { return }
        if event.type == "rendered" {
          showingDocument = true
          heldNotice = nil
        }
        if event.type == "openFile", let side = event.side { store.send(.openFile(side, event.line)) }
        if event.type == "error", let message = event.message { store.send(.rendererFailed(message)) }
      }
      .id(store.rendererGeneration)
      .opacity(documentVisible ? 1 : 0)
      .allowsHitTesting(documentVisible)
      .accessibilityHidden(!documentVisible)
      if let error = store.error {
        message(error, symbol: "exclamationmark.triangle")
      } else if comparisonIsEmpty {
        message(
          outgoing ? "No committed changes against this base." : "No changes in this worktree.",
          symbol: "checkmark.circle")
      } else if !documentVisible {
        if let notice = store.notice ?? (store.document != nil ? heldNotice : nil) {
          message(notice, symbol: "doc.text.magnifyingglass")
        } else if store.document == nil && (store.contentLoading || store.snapshot == nil) {
          if slowLoading { ProgressView("Loading changes…").controlSize(.small) }
        } else if store.document == nil {
          message("Select a file to view its changes.", symbol: "doc.text")
        }
      }
    }
    .onChange(of: store.document?.id) { _, id in if id == nil { showingDocument = false } }
    .onChange(of: store.rendererGeneration) { _, _ in showingDocument = false }
    .onChange(of: store.notice) { _, notice in if let notice { heldNotice = notice } }
    .task(id: loadingKey) {
      slowLoading = false
      guard loadingKey != nil else { return }
      try? await Task.sleep(for: .milliseconds(300))
      if !Task.isCancelled { slowLoading = true }
    }
  }

  private func message(_ text: String, symbol: String) -> some View {
    VStack(spacing: 8) {
      Image(systemName: symbol).font(.title2).accessibilityHidden(true)
      Text(text).font(.callout).multilineTextAlignment(.center).textSelection(.enabled)
    }
    .foregroundStyle(.secondary).padding(24)
    .frame(maxWidth: .infinity, maxHeight: .infinity)
  }
}

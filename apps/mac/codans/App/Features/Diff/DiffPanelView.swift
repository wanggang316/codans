import CodansCore
import ComposableArchitecture
import DiffViewKit
import SwiftUI

struct DiffPanelView: View {
  @Bindable var store: StoreOf<DiffFeature>
  @Environment(\.colorScheme) private var colorScheme

  private var outgoing: Bool { store.state.scope == .outgoing }
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
      DiffFileIcon(path: selectedFile?.path ?? "")
      Text(selectedFile?.path ?? (outgoing ? "Outgoing" : "Uncommitted"))
        .font(.system(size: 12)).lineLimit(1).truncationMode(.middle)
        .help(selectedFile?.path ?? "Select a file")
      Spacer(minLength: 8)
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
        if event.type == "openFile", let side = event.side { store.send(.openFile(side, event.line)) }
        if event.type == "error", let message = event.message { store.send(.rendererFailed(message)) }
      }
      .id(store.rendererGeneration)
      .opacity(store.document == nil ? 0 : 1)
      .allowsHitTesting(store.document != nil)
      .accessibilityHidden(store.document == nil)
      if let error = store.error {
        message(error, symbol: "exclamationmark.triangle")
      } else if let snapshot = store.snapshot, snapshot.files.isEmpty {
        message(
          outgoing ? "No committed changes against this base." : "No changes in this worktree.",
          symbol: "checkmark.circle")
      } else if store.document == nil {
        if let notice = store.notice {
          message(notice, symbol: "doc.text.magnifyingglass")
        } else if store.contentLoading || store.snapshot == nil {
          ProgressView("Loading changes…").controlSize(.small)
        } else {
          message("Select a file to view its changes.", symbol: "doc.text")
        }
      }
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

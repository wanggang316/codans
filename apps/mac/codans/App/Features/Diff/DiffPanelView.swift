import CodansCore
import ComposableArchitecture
import DiffViewKit
import SwiftUI

struct DiffPanelView: View {
  @Bindable var store: StoreOf<DiffFeature>
  @Environment(\.colorScheme) private var colorScheme

  private var outgoing: Bool { store.state.scope == .outgoing }
  private var files: [GitComparisonFile] {
    (store.snapshot?.files ?? []).filter {
      store.filter.isEmpty || $0.path.localizedCaseInsensitiveContains(store.filter)
    }
  }

  var body: some View {
    VStack(spacing: 0) {
      header
      Divider()
      controls
      ZStack {
        HSplitView {
          fileList.frame(minWidth: 150, idealWidth: 200, maxWidth: 330)
          content.frame(minWidth: 200, maxWidth: .infinity, maxHeight: .infinity)
        }
        .opacity(hasFiles ? 1 : 0)
        .allowsHitTesting(hasFiles)
        .accessibilityHidden(!hasFiles)
        if let error = store.error {
          message(error, symbol: "exclamationmark.triangle")
        } else if let snapshot = store.snapshot, snapshot.files.isEmpty {
          message(
            outgoing ? "No committed changes against this base." : "No changes in this scope.",
            symbol: "checkmark.circle")
        } else if store.snapshot == nil {
          ProgressView("Loading changes…")
        }
      }
      if let message = store.editorMessage {
        Text(message).font(.caption).foregroundStyle(.secondary)
          .frame(maxWidth: .infinity, alignment: .leading).padding(8)
      }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .background(.background)
    .accessibilityIdentifier("diff-panel")
  }

  private var header: some View {
    HStack(spacing: 8) {
      Picker(
        "Comparison",
        selection: Binding(
          get: { outgoing },
          set: { store.send(.scopeChanged($0 ? .outgoing : .all)) }
        )
      ) {
        Text("Changes").tag(false)
        Text("Outgoing").tag(true)
      }
      .pickerStyle(.segmented)
      .labelsHidden()
      .frame(maxWidth: 220)
      Spacer(minLength: 0)
      if store.loading && store.snapshot == nil { ProgressView().controlSize(.small) }
      Button {
        store.send(.refresh)
      } label: {
        Image(systemName: "arrow.clockwise").accessibilityLabel("Refresh Changes")
      }
      .help("Refresh local Git state")

    }
    .buttonStyle(.borderless)
    .padding(10)
  }

  private var controls: some View {
    VStack(alignment: .leading, spacing: 8) {
      if outgoing {
        HStack {
          TextField(
            "Base branch (automatic)", text: Binding(get: { store.base }, set: { store.send(.baseChanged($0)) })
          )
          .textFieldStyle(.roundedBorder)
          .onSubmit { store.send(.refresh) }
          .accessibilityIdentifier("diff-base")
          Button("Compare") { store.send(.refresh) }
        }
      } else {
        Picker("Change scope", selection: Binding(get: { store.state.scope }, set: { store.send(.scopeChanged($0)) })) {
          Text("All").tag(GitComparisonScope.all)
          Text("Staged").tag(GitComparisonScope.staged)
          Text("Unstaged").tag(GitComparisonScope.unstaged)
        }
        .pickerStyle(.segmented)
        .labelsHidden()
      }
      HStack {
        Button("Open Selected File") { store.send(.openFile("new", nil)) }
          .disabled(store.selectedFileID == nil)
          .help("Opens the current file in your configured editor")
        Spacer()
      }
      Text(
        store.snapshot.map { outgoing ? "Against \($0.baseLabel) · local refs" : $0.baseLabel }
          ?? "Read-only comparison"
      )
      .font(.caption).foregroundStyle(.secondary)
    }
    .padding(10)
  }

  private var fileList: some View {
    VStack(spacing: 0) {
      TextField("Filter files", text: Binding(get: { store.filter }, set: { store.send(.filterChanged($0)) }))
        .textFieldStyle(.roundedBorder).padding(8)
        .accessibilityIdentifier("diff-file-filter")
      List(selection: Binding(get: { store.selectedFileID }, set: { if let id = $0 { store.send(.selectFile(id)) } })) {
        ForEach(files) { file in
          HStack(alignment: .top, spacing: 8) {
            Text(file.status).font(.caption.monospaced()).foregroundStyle(.secondary).frame(width: 16)
            VStack(alignment: .leading, spacing: 3) {
              Text(file.path).font(.system(size: 11, design: .monospaced)).lineLimit(2)
              if let added = file.additions, let removed = file.deletions {
                Text("+\(added) −\(removed)").font(.caption2).foregroundStyle(.secondary)
              }
            }
          }
          .tag(file.id)
          .padding(.vertical, 3)
          .help(file.path)
        }
      }
      .listStyle(.sidebar)
      if files.isEmpty { Text("No matching files").font(.caption).padding() }
    }
  }

  private var hasFiles: Bool { store.error == nil && store.snapshot?.files.isEmpty == false }

  private var content: some View {
    ZStack {
      // Keep the Web process and user-selected presentation alive while Git
      // snapshots reload or the selected file changes.
      DiffView(
        document: store.document ?? DiffDocument(id: "empty", path: "empty.txt", oldText: "", newText: ""),
        options: DiffOptions(theme: colorScheme == .dark ? "dark" : "light")
      ) { event in
        guard event.documentID == nil || event.documentID == store.document?.id else { return }
        if event.type == "openFile", let side = event.side { store.send(.openFile(side, event.line)) }
        if event.type == "error", let message = event.message { store.send(.rendererFailed(message)) }
      }
      .id(store.rendererGeneration)
      .opacity(store.document == nil ? 0 : 1)
      .allowsHitTesting(store.document != nil)
      .accessibilityHidden(store.document == nil)
      if store.document == nil {
        if let notice = store.notice {
          message(notice, symbol: "doc.text.magnifyingglass")
        } else if store.contentLoading {
          ProgressView("Loading file…")
        } else {
          message("Select a file to view its changes.", symbol: "doc.text")
        }
      }
    }
  }

  private func message(_ text: String, symbol: String) -> some View {
    VStack(spacing: 12) {
      Image(systemName: symbol).font(.title).accessibilityHidden(true)
      Text(text).font(.callout).multilineTextAlignment(.center).textSelection(.enabled)
    }
    .foregroundStyle(.secondary).padding(24)
    .frame(maxWidth: .infinity, maxHeight: .infinity)
  }
}

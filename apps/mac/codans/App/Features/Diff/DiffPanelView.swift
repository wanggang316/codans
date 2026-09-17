import CodansCore
import ComposableArchitecture
import DiffViewKit
import SwiftUI

struct DiffPanelView: View {
  @Bindable var store: StoreOf<DiffFeature>
  @Environment(\.colorScheme) private var colorScheme
  @State private var showingBase = false

  private var outgoing: Bool { store.state.scope == .outgoing }
  private var selectedFile: GitComparisonFile? {
    store.snapshot?.files.first { $0.id == store.selectedFileID }
  }
  private var files: [GitComparisonFile] {
    (store.snapshot?.files ?? []).filter {
      store.filter.isEmpty || $0.path.localizedCaseInsensitiveContains(store.filter)
    }
  }

  var body: some View {
    HSplitView {
      fileList.frame(minWidth: 200, idealWidth: 240, maxWidth: 280)
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
    .background(Color(nsColor: .textBackgroundColor))
    .accessibilityIdentifier("diff-panel")
  }

  private var fileHeader: some View {
    HStack(spacing: 8) {
      Image(systemName: "doc.text").foregroundStyle(.secondary).accessibilityHidden(true)
      Text(selectedFile?.path ?? "Changes")
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

  private var fileList: some View {
    VStack(spacing: 0) {
      HStack {
        Text("Changed Files").font(.system(size: 11, weight: .semibold))
        Spacer()
        Text("\(store.snapshot?.files.count ?? 0)").font(.system(size: 11).monospacedDigit())
      }
      .foregroundStyle(.secondary).padding(.horizontal, 12).frame(height: 32)
      Divider()
      HStack(spacing: 6) {
        Image(systemName: "magnifyingglass").foregroundStyle(.secondary).accessibilityHidden(true)
        TextField("Filter files", text: Binding(get: { store.filter }, set: { store.send(.filterChanged($0)) }))
          .textFieldStyle(.plain)
          .accessibilityIdentifier("diff-file-filter")
      }
      .font(.system(size: 12))
      .padding(.horizontal, 8).padding(.vertical, 5)
      .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 6))
      .padding(8)
      List(selection: Binding(get: { store.selectedFileID }, set: { if let id = $0 { store.send(.selectFile(id)) } })) {
        ForEach(files) { file in
          HStack(spacing: 8) {
            Image(systemName: "doc.text").foregroundStyle(.secondary).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
              Text((file.path as NSString).lastPathComponent).lineLimit(1).truncationMode(.middle)
              let directory = (file.path as NSString).deletingLastPathComponent
              if !directory.isEmpty {
                Text(directory).font(.system(size: 11)).foregroundStyle(.secondary)
                  .lineLimit(1).truncationMode(.middle)
              }
            }
            Spacer(minLength: 4)
            Text(file.status).font(.system(size: 10, weight: .semibold))
              .foregroundStyle(statusColor(file.status))
          }
          .font(.system(size: 13))
          .tag(file.id)
          .help(file.path)
          .contextMenu {
            Button("Open in Editor") {
              store.send(.selectFile(file.id))
              store.send(.openFile("new", nil))
            }
            .disabled(file.status == "D")
          }
        }
      }
      .listStyle(.sidebar)
      .environment(\.defaultMinListRowHeight, 28)
      .overlay {
        if files.isEmpty, store.snapshot?.files.isEmpty == false {
          Text("No matching files").font(.caption).foregroundStyle(.secondary)
        }
      }
      if outgoing {
        Divider()
        Button {
          showingBase.toggle()
        } label: {
          HStack(spacing: 6) {
            Image(systemName: "arrow.triangle.branch").accessibilityHidden(true)
            Text("Against \(store.snapshot?.baseLabel ?? "automatic")").lineLimit(1).truncationMode(.middle)
            Spacer(minLength: 0)
            Image(systemName: "chevron.down").font(.system(size: 9)).accessibilityHidden(true)
          }
          .font(.system(size: 11)).foregroundStyle(.secondary)
          .padding(.horizontal, 12).frame(height: 30)
          .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Choose the comparison base")
        .popover(isPresented: $showingBase) {
          VStack(alignment: .leading, spacing: 12) {
            Text("Compare Against").font(.headline)
            TextField(
              "Automatic base branch", text: Binding(get: { store.base }, set: { store.send(.baseChanged($0)) })
            )
            .textFieldStyle(.roundedBorder).accessibilityIdentifier("diff-base")
            .onSubmit { applyBase() }
            HStack {
              Text("Uses local Git refs").font(.caption).foregroundStyle(.secondary)
              Spacer()
              Button("Compare") { applyBase() }.keyboardShortcut(.defaultAction)
            }
          }
          .padding(16).frame(width: 280)
        }
      }
    }
    .background(Color(nsColor: .windowBackgroundColor))
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

  private func applyBase() {
    store.send(.refresh)
    showingBase = false
  }

  private func statusColor(_ status: String) -> Color {
    switch status {
    case "A": ThemeGit.kindAdded
    case "D": ThemeGit.kindDeleted
    case "M": ThemeGit.kindModified
    case "R": ThemeGit.kindRenamed
    default: .secondary
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

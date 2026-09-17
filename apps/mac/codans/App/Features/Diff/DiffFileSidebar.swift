import CodansCore
import ComposableArchitecture
import SwiftUI

struct DiffFileSidebar: View {
  @Bindable var store: StoreOf<DiffFeature>
  @State private var showingBase = false
  @State private var collapsedFolders: Set<String> = []

  private var outgoing: Bool { store.state.scope == .outgoing }
  private var files: [GitComparisonFile] {
    (store.snapshot?.files ?? []).filter {
      store.filter.isEmpty || $0.path.localizedCaseInsensitiveContains(store.filter)
    }.sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
  }

  var body: some View {
    VStack(spacing: 0) {
      DiffComparisonPicker(
        outgoing: Binding(
          get: { outgoing }, set: { store.send(.scopeChanged($0 ? .outgoing : .all)) }
        )
      )
      .frame(maxWidth: .infinity).frame(height: 24)
      .padding(.horizontal, 10).padding(.vertical, 4)
      Divider()
      HStack {
        Text("Changed Files").font(.system(size: 11, weight: .semibold))
        Text("\(store.snapshot?.files.count ?? 0)").font(.system(size: 11).monospacedDigit())
        Spacer(minLength: 8)
        Picker(
          "File presentation",
          selection: Binding(
            get: { store.filePresentation }, set: { store.send(.filePresentationChanged($0)) }
          )
        ) {
          Image(systemName: "list.bullet.indent").accessibilityLabel("Tree").tag(DiffFeature.FilePresentation.tree)
          Image(systemName: "list.bullet").accessibilityLabel("List").tag(DiffFeature.FilePresentation.list)
        }
        .pickerStyle(.segmented).labelsHidden().controlSize(.small).fixedSize()
        .help("Show files as a tree or a flat list")
        .accessibilityIdentifier("diff-file-presentation")
      }
      .foregroundStyle(.secondary).padding(.horizontal, 10).frame(height: 32)
      HStack(spacing: 6) {
        Image(systemName: "magnifyingglass").foregroundStyle(.secondary).accessibilityHidden(true)
        TextField("Filter files", text: Binding(get: { store.filter }, set: { store.send(.filterChanged($0)) }))
          .textFieldStyle(.plain).accessibilityIdentifier("diff-file-filter")
      }
      .font(.system(size: 12)).padding(.horizontal, 8).padding(.vertical, 5)
      .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 6))
      .padding(.horizontal, 8).padding(.bottom, 6)
      List(
        selection: Binding(
          get: { store.selectedFileID },
          set: { id in
            if let id, store.snapshot?.files.contains(where: { $0.id == id }) == true { store.send(.selectFile(id)) }
          })
      ) {
        if store.filePresentation == .tree {
          DiffFileTreeRows(nodes: DiffFileTreeNode.build(files), collapsedFolders: $collapsedFolders, store: store)
        } else {
          ForEach(files) { file in
            DiffFileSidebarRow(file: file, showsDirectory: true, store: store)
          }
        }
      }
      .listStyle(.sidebar).environment(\.defaultMinListRowHeight, 28)
      .overlay {
        if files.isEmpty, store.snapshot?.files.isEmpty == false {
          Text("No matching files").font(.caption).foregroundStyle(.secondary)
        }
      }
      if outgoing { baseControl }
    }
    .onChange(of: store.filter) { _, query in
      if !query.isEmpty { collapsedFolders.removeAll() }
    }
    .onChange(of: store.selectedFileID) { _, _ in revealSelection() }
    .onChange(of: store.filePresentation) { _, _ in revealSelection() }
  }

  private func revealSelection() {
    guard let file = store.snapshot?.files.first(where: { $0.id == store.selectedFileID }) else { return }
    var directory = (file.path as NSString).deletingLastPathComponent
    while !directory.isEmpty {
      collapsedFolders.remove("dir:\(directory)")
      directory = (directory as NSString).deletingLastPathComponent
    }
  }

  private var baseControl: some View {
    VStack(spacing: 0) {
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
        .padding(.horizontal, 12).frame(height: 30).contentShape(Rectangle())
      }
      .buttonStyle(.plain).help("Choose the comparison base")
      .popover(isPresented: $showingBase) {
        VStack(alignment: .leading, spacing: 12) {
          Text("Compare Against").font(.headline)
          TextField("Remote default branch", text: Binding(get: { store.base }, set: { store.send(.baseChanged($0)) }))
            .textFieldStyle(.roundedBorder).accessibilityIdentifier("diff-base")
            .onSubmit { applyBase() }
          HStack {
            Button("Use Remote Default") {
              store.send(.baseChanged(""))
              applyBase()
            }
            .controlSize(.small)
            Spacer()
            Button("Compare") { applyBase() }.keyboardShortcut(.defaultAction)
          }
        }
        .padding(16).frame(width: 280)
      }
    }
  }

  private func applyBase() {
    store.send(.refresh)
    showingBase = false
  }
}

private struct DiffFileTreeRows: View {
  let nodes: [DiffFileTreeNode]
  @Binding var collapsedFolders: Set<String>
  let store: StoreOf<DiffFeature>

  var body: some View {
    ForEach(nodes) { node in
      if let children = node.children {
        DisclosureGroup(
          isExpanded: Binding(
            get: { !collapsedFolders.contains(node.id) },
            set: { expanded in
              if expanded { collapsedFolders.remove(node.id) } else { collapsedFolders.insert(node.id) }
            }
          )
        ) {
          DiffFileTreeRows(nodes: children, collapsedFolders: $collapsedFolders, store: store)
        } label: {
          Label(node.name, systemImage: "folder").font(.system(size: 13))
            .lineLimit(1).help(node.path)
        }
      } else if let file = node.file {
        DiffFileSidebarRow(file: file, showsDirectory: false, store: store)
      }
    }
  }
}

private struct DiffFileSidebarRow: View {
  let file: GitComparisonFile
  let showsDirectory: Bool
  let store: StoreOf<DiffFeature>

  var body: some View {
    HStack(spacing: 8) {
      DiffFileIcon(path: file.path)
      VStack(alignment: .leading, spacing: 2) {
        Text((file.path as NSString).lastPathComponent).lineLimit(1).truncationMode(.middle)
        let directory = (file.path as NSString).deletingLastPathComponent
        if showsDirectory && !directory.isEmpty {
          Text(directory).font(.system(size: 11)).foregroundStyle(.secondary)
            .lineLimit(1).truncationMode(.middle)
        }
      }
      Spacer(minLength: 4)
      Text(file.status).font(.system(size: 10, weight: .semibold)).foregroundStyle(statusColor)
    }
    .font(.system(size: 13)).tag(file.id).help(file.path)
    .contextMenu {
      Button("Open in Editor") {
        store.send(.selectFile(file.id))
        store.send(.openFile("new", nil))
      }.disabled(file.status == "D")
    }
  }

  private var statusColor: Color {
    switch file.status {
    case "A": ThemeGit.kindAdded
    case "D": ThemeGit.kindDeleted
    case "M": ThemeGit.kindModified
    case "R": ThemeGit.kindRenamed
    default: .secondary
    }
  }
}

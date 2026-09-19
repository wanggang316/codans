import CodansCore
import ComposableArchitecture
import SwiftUI

struct DiffFileSidebar: View {
  @Bindable var store: StoreOf<DiffFeature>
  @State private var showingBase = false
  @State private var collapsedFolders: Set<String> = []
  @State private var listGeneration = 0

  private var outgoing: Bool { store.state.scope == .outgoing }
  /// The comparison arrives in display order, so the list only filters it.
  private var files: [GitComparisonFile] {
    let all = store.snapshot?.files ?? []
    return store.filter.isEmpty ? all : all.filter { $0.path.localizedCaseInsensitiveContains(store.filter) }
  }

  /// File rows the list shows: in the tree, only those outside collapsed folders.
  private func visibleFileIDs(_ files: [GitComparisonFile], tree nodes: [DiffFileTreeNode]) -> [String] {
    guard store.filePresentation == .tree else { return files.map(\.id) }
    func visible(_ nodes: [DiffFileTreeNode]) -> [String] {
      nodes.flatMap { node -> [String] in
        if let children = node.children { return collapsedFolders.contains(node.id) ? [] : visible(children) }
        return node.file.map { [$0.id] } ?? []
      }
    }
    return visible(nodes)
  }

  private struct ListRows: Equatable {
    var fileIDs: [String]
    var selectedFileID: String?
  }

  var body: some View {
    // Filtered and built once per render: a comparison can hold thousands of files.
    let files = self.files
    let nodes = store.filePresentation == .tree ? DiffFileTreeNode.build(files) : []
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
        VStack(alignment: .leading, spacing: 3) {
          Text("Changed Files \(store.snapshot?.files.count ?? 0)")
            .font(.system(size: 11, weight: .semibold))
          let totals = store.snapshot?.lineTotals
          DiffLineCounts(additions: totals?.additions ?? 0, deletions: totals?.deletions ?? 0)
            .help(
              "Total text changes across all files, including files hidden by the filter. Files without line counts are excluded."
            )
            .accessibilityIdentifier("diff-total-line-counts")
        }
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
      .foregroundStyle(.secondary).padding(.horizontal, 10).frame(height: 44)
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
          DiffFileTreeRows(nodes: nodes, collapsedFolders: $collapsedFolders, store: store)
        } else {
          ForEach(files) { file in
            DiffFileSidebarRow(file: file, showsDirectory: true, store: store)
          }
        }
      }
      .listStyle(.sidebar).environment(\.defaultMinListRowHeight, 28)
      .id(listGeneration)
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
    .onChange(of: ListRows(fileIDs: visibleFileIDs(files, tree: nodes), selectedFileID: store.selectedFileID)) {
      old, new in
      // The macOS List leaves a user-selected row on screen after that row is removed (scope
      // switch, refresh without the file, filter, collapsing its folder), drawn over the rows
      // below. A fresh List discards it; other updates keep the list, its scroll and focus.
      if let selected = old.selectedFileID, old.fileIDs.contains(selected), !new.fileIDs.contains(selected) {
        listGeneration += 1
      }
    }
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
        if showingBase { store.send(.loadBaseBranches) }
      } label: {
        HStack(spacing: 6) {
          Image(systemName: "arrow.triangle.branch").accessibilityHidden(true)
          Text("Against \(baseLabel)").lineLimit(1).truncationMode(.middle)
          Spacer(minLength: 0)
          Image(systemName: "chevron.down").font(.system(size: 9)).accessibilityHidden(true)
        }
        .font(.system(size: 11)).foregroundStyle(.secondary)
        .padding(.horizontal, 12).frame(height: 30).contentShape(Rectangle())
      }
      .buttonStyle(.plain).help("Choose the comparison base")
      .popover(isPresented: $showingBase) {
        VStack(alignment: .leading, spacing: 8) {
          Text("Compare Against").font(.headline).padding(.horizontal, 8)
          baseOption("Remote Default Branch", ref: "")
          Divider()
          if store.baseBranchesLoading {
            ProgressView().controlSize(.small).frame(maxWidth: .infinity).padding(12)
          } else if let error = store.baseBranchesError {
            Text(error).font(.caption).foregroundStyle(.secondary)
            Button("Retry") { store.send(.loadBaseBranches) }
          } else if let inventory = store.baseBranches {
            if inventory.remote.isEmpty && inventory.local.isEmpty {
              Text("No branches available").font(.caption).foregroundStyle(.secondary).padding(8)
            } else {
              ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                  branchSection("Remote Branches", branches: inventory.remote)
                  branchSection("Local Branches", branches: inventory.local)
                }
              }
              .frame(height: min(280, CGFloat(inventory.remote.count + inventory.local.count) * 30 + 52))
            }
          }
        }
        .padding(12).frame(width: 300)
      }
    }
  }

  private var baseLabel: String {
    let value = store.snapshot?.baseLabel ?? "automatic"
    for prefix in ["refs/remotes/", "refs/heads/"] where value.hasPrefix(prefix) {
      return String(value.dropFirst(prefix.count))
    }
    return value
  }

  @ViewBuilder
  private func branchSection(_ title: String, branches: [BranchRef]) -> some View {
    if !branches.isEmpty {
      Text(title).font(.caption).foregroundStyle(.secondary).padding(.horizontal, 8).padding(.top, 6)
      let sorted = branches.sorted { $0.shortName.localizedStandardCompare($1.shortName) == .orderedAscending }
      ForEach(sorted, id: \.self) { branch in
        baseOption(branch.shortName, ref: (branch.isRemote ? "refs/remotes/" : "refs/heads/") + branch.shortName)
      }
    }
  }

  private func baseOption(_ title: String, ref: String) -> some View {
    let selected = store.appliedBase == ref || (!ref.isEmpty && store.appliedBase == title)
    return Button {
      store.send(.baseSelected(ref))
      showingBase = false
    } label: {
      HStack(spacing: 8) {
        Image(systemName: "checkmark").opacity(selected ? 1 : 0).accessibilityHidden(true)
        Text(title).lineLimit(1).truncationMode(.middle)
        Spacer(minLength: 0)
      }
      .font(.system(size: 12))
      .padding(.horizontal, 8).padding(.vertical, 6)
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .background(selected ? Color.accentColor.opacity(0.12) : Color.clear, in: RoundedRectangle(cornerRadius: 5))
    .accessibilityAddTraits(selected ? .isSelected : [])
    .help(title)
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
        .frame(width: 9)
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

private struct DiffLineCounts: View {
  let additions: Int?
  let deletions: Int?

  var body: some View {
    HStack(spacing: 4) {
      if let additions, let deletions {
        Text("+\(additions)").foregroundStyle(ThemeGit.added)
        Text("−\(deletions)").foregroundStyle(ThemeGit.removed)
      } else {
        Text("—").foregroundStyle(.secondary)
          .accessibilityLabel("Line counts unavailable")
      }
    }
    .font(.system(size: 10).monospacedDigit())
    .fixedSize()
    .accessibilityElement(children: .combine)
  }
}

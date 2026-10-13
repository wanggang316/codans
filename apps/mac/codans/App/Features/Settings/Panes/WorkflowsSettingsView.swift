import AppKit
import CodansCore
import ComposableArchitecture
import SwiftUI

/// Settings → Agents → Workflows. Lists every discovered
/// `<id>.workflow.yaml` across the three scopes (bundle, user, one section
/// per repository), with an enable switch, live diagnostics, remembered
/// `launch` role bindings, and repository-file trust — the Settings surface
/// `docs/design-docs/workflow.md` describes under "可观测性与 UI".
///
/// The lists come from `WorkflowCatalogStore`, which watches the files, so
/// an edit saved in an editor or a file an agent writes shows up (and
/// revalidates) without a refresh; the button only forces a rescan.
struct WorkflowsSettingsView: View {
  @Environment(SettingsStore.self) private var settingsStore
  @Environment(HierarchyManager.self) private var hierarchyManager
  @Environment(WorkflowCatalogStore.self) private var catalog

  @State private var trustPrompt: TrustPromptTarget?
  @State private var newWorkflow: NewWorkflowRequest?
  @State private var trashCandidate: WorkflowCatalogEntry?
  @State private var isAskingAgent = false
  /// Non-nil = the detail screen for the file at this path is showing.
  /// Keyed by path, not id: the same id can exist in several scopes.
  @State private var detailPath: String?

  /// What the New Workflow sheet opens with: blank, or a duplicate.
  private struct NewWorkflowRequest: Identifiable {
    let id = UUID()
    var name = ""
    var starterID: String?
  }

  private struct TrustPromptTarget: Identifiable {
    let entry: WorkflowCatalogEntry
    var id: String { entry.path }
  }

  private var workflows: WorkflowSettings { settingsStore.settings.workflows }

  private var eligibleProjects: [Project] {
    WorkflowsSettingsLogic.eligibleRepositoryProjects(hierarchyManager.catalog.projects)
  }

  /// Repository scopes are keyed by the project's main checkout — the same
  /// directory the watched catalog follows for that worktree.
  private var repositoryGroups: [WorkflowsSettingsLogic.RepositoryGroup] {
    var scanned: [ProjectID: [WorkflowCatalogEntry]] = [:]
    for project in eligibleProjects {
      scanned[project.id] = catalog.repositories[project.rootPath] ?? []
    }
    return WorkflowsSettingsLogic.repositoryGroups(eligibleProjects: eligibleProjects, scanned: scanned)
  }

  var body: some View {
    Group {
      if let detailPath {
        detail(path: detailPath)
      } else {
        list
      }
    }
    .onChange(of: catalog.isNewWorkflowRequested, initial: true) {
      if catalog.consumeNewWorkflowRequest() {
        detailPath = nil
        newWorkflow = NewWorkflowRequest()
      }
    }
    .sheet(item: $newWorkflow) { request in
      NewWorkflowSheet(
        locations: newWorkflowLocations,
        starters: newWorkflowStarters,
        initialName: request.name,
        initialStarterID: request.starterID,
        onCreated: { url, location in
          newWorkflow = nil
          catalog.rescanAll()
          detailPath = url.path(percentEncoded: false)
          Task { await open(url, projectID: location.projectID) }
        },
        onCancel: { newWorkflow = nil }
      )
    }
    .sheet(isPresented: $isAskingAgent) {
      AskAgentForWorkflowSheet(userDirectory: userDirectoryDisplayPath) { isAskingAgent = false }
    }
    .confirmationDialog(
      "Move \"\(trashCandidate?.name ?? "")\" to the Trash?",
      isPresented: Binding(get: { trashCandidate != nil }, set: { if !$0 { trashCandidate = nil } }),
      presenting: trashCandidate
    ) { entry in
      Button("Move to Trash", role: .destructive) { moveToTrash(entry) }
    } message: { entry in
      Text("\((entry.path as NSString).abbreviatingWithTildeInPath) can be restored from the Trash.")
    }
    .sheet(item: $trustPrompt) { target in
      WorkflowTrustConfirmationSheet(
        entry: target.entry,
        onConfirm: { trust(target.entry) },
        onCancel: { trustPrompt = nil }
      )
    }
  }

  // MARK: - Detail

  /// Every listed file, in list order.
  private var allEntries: [WorkflowCatalogEntry] {
    catalog.bundle + catalog.user + repositoryGroups.flatMap(\.entries)
  }

  private func detail(path: String) -> some View {
    let entry = allEntries.first { $0.path == path }
    return WorkflowDetailView(
      entry: entry,
      projectID: entry.flatMap(projectID(of:)),
      onBack: { detailPath = nil },
      onOpen: {
        if let entry { Task { await open(URL(fileURLWithPath: entry.path), projectID: projectID(of: entry)) } }
      },
      onReveal: { if let entry { reveal(entry) } },
      onDuplicate: { if let entry { duplicate(entry) } },
      onTrash: { trashCandidate = entry },
      onTrust: { if let entry { trustPrompt = TrustPromptTarget(entry: entry) } }
    )
  }

  // MARK: - List

  private var list: some View {
    Form {
      masterSection
      scopeSection(title: "Built-in", entries: catalog.bundle, emptyText: "No built-in workflows.")
      userScopeSection
      ForEach(repositoryGroups) { group in
        scopeSection(title: "Repository — \(group.projectName)", entries: group.entries, emptyText: "")
      }
    }
    .formStyle(.grouped)
  }

  // MARK: - Master

  private var masterSection: some View {
    Section {
      HStack {
        Toggle("Enable Agent Workflows", isOn: enabledBinding)
        Spacer()
        Button {
          catalog.rescanAll()
        } label: {
          Image(systemName: "arrow.clockwise")
        }
        .buttonStyle(.borderless)
        .help("Rescan workflow files (changes on disk are picked up automatically)")
      }
      HStack {
        VStack(alignment: .leading, spacing: 2) {
          Text("New workflow")
          Text("Start from a blank starter or a copy, or have an agent write one.")
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        Spacer()
        Button("Ask an Agent…") { isAskingAgent = true }
          .accessibilityIdentifier("settings.workflows.askAgent")
        Button("New Workflow…") { newWorkflow = NewWorkflowRequest() }
          .accessibilityIdentifier("settings.workflows.new")
      }
    } footer: {
      Text("Turning this off removes the `codans workflow` commands and palette entries.")
    }
  }

  // MARK: - New workflow

  /// The user scope first, then every repository the scan would list.
  private var newWorkflowLocations: [NewWorkflowSheet.Location] {
    let user = NewWorkflowSheet.Location(
      id: "user", title: "User", directory: AppDirectories.workflowsDirectory(),
      worktreeRoot: nil, projectID: nil)
    let repositories = eligibleProjects.map { project in
      let root = URL(fileURLWithPath: project.rootPath, isDirectory: true)
      return NewWorkflowSheet.Location(
        id: project.id.raw.uuidString, title: "Repository — \(project.name)",
        directory: WorkflowDiscovery.repositoryDirectory(worktreeRoot: root), worktreeRoot: root,
        projectID: project.id)
    }
    return [user] + repositories
  }

  /// Blank, then a copy of every definition that currently validates.
  private var newWorkflowStarters: [NewWorkflowSheet.Starter] {
    let blank = NewWorkflowSheet.Starter(id: "blank", title: "Blank starter", source: .blank)
    let groups: [(String, [WorkflowCatalogEntry])] =
      [("Built-in", catalog.bundle), ("User", catalog.user)]
      + repositoryGroups.map { ($0.projectName, $0.entries) }
    let copies = groups.flatMap { scope, entries in
      entries.filter(\.isValid).map { entry in
        NewWorkflowSheet.Starter(
          id: entry.path, title: "Copy of \(entry.name) (\(scope))", source: .copy(yaml: entry.yaml))
      }
    }
    return [blank] + copies
  }

  /// Opens a workflow file in the user's editor — the project's default for
  /// a repository file — and falls back to Finder when no editor can.
  private func open(_ url: URL, projectID: ProjectID?) async {
    @Dependency(DiffEditorClient.self) var editor
    do {
      try await editor.openFile(url.deletingLastPathComponent(), url.lastPathComponent, nil, projectID)
    } catch {
      NSWorkspace.shared.activateFileViewerSelecting([url])
    }
  }

  /// The repository project a file belongs to, for its editor preference.
  private func projectID(of entry: WorkflowCatalogEntry) -> ProjectID? {
    guard entry.scope == .repo else { return nil }
    return eligibleProjects.first { entry.path.hasPrefix($0.rootPath + "/") }?.id
  }

  private func duplicate(_ entry: WorkflowCatalogEntry) {
    newWorkflow = NewWorkflowRequest(name: "\(entry.name) Copy", starterID: entry.path)
  }

  private func moveToTrash(_ entry: WorkflowCatalogEntry) {
    try? FileManager.default.trashItem(at: URL(fileURLWithPath: entry.path), resultingItemURL: nil)
    if detailPath == entry.path { detailPath = nil }
    catalog.rescanAll()
  }

  private var enabledBinding: Binding<Bool> {
    Binding(
      get: { workflows.isEnabled },
      set: { newValue in settingsStore.mutateWorkflows { $0.isEnabled = newValue } }
    )
  }

  // MARK: - Scopes

  @ViewBuilder
  private func scopeSection(title: String, entries: [WorkflowCatalogEntry], emptyText: String) -> some View {
    Section(title) {
      if entries.isEmpty {
        Text(emptyText)
          .foregroundStyle(.secondary)
      } else {
        ForEach(entries, id: \.id) { entry in
          workflowRow(entry)
        }
      }
    }
  }

  private var userScopeSection: some View {
    Section("User") {
      LabeledContent("Directory") {
        HStack(spacing: 6) {
          Text(userDirectoryDisplayPath)
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .truncationMode(.middle)
          Button {
            revealUserDirectory()
          } label: {
            Image(systemName: "folder")
          }
          .buttonStyle(.borderless)
          .help("Show in Finder")
        }
      }
      if catalog.user.isEmpty {
        Text("No workflows in \(userDirectoryDisplayPath) yet.")
          .foregroundStyle(.secondary)
      } else {
        ForEach(catalog.user, id: \.id) { entry in
          workflowRow(entry)
        }
      }
    }
  }

  private var userDirectoryDisplayPath: String {
    (AppDirectories.workflowsDirectory().path(percentEncoded: false) as NSString).abbreviatingWithTildeInPath
  }

  // MARK: - Row

  /// Enable checkbox beside — not inside — a button into the detail screen,
  /// the Agents pane's row shape: a Toggle nested in the Button would be
  /// uncheckable.
  private func workflowRow(_ entry: WorkflowCatalogEntry) -> some View {
    HStack(spacing: 8) {
      Toggle(isOn: rowEnabledBinding(for: entry)) {
        EmptyView()
      }
      .labelsHidden()
      .toggleStyle(.checkbox)
      .accessibilityLabel("Enable \(entry.name)")

      Button {
        detailPath = entry.path
      } label: {
        HStack(spacing: 8) {
          VStack(alignment: .leading, spacing: 2) {
            Text(entry.name)
              .lineLimit(1)
            Text(entry.definition?.description ?? entry.id)
              .font(.caption)
              .foregroundStyle(.secondary)
              .lineLimit(1)
          }
          Spacer(minLength: 12)
          WorkflowStatusLabel(entry: entry, isDisabled: workflows.isDisabled(entry.id))
            .font(.caption)
          Image(systemName: "chevron.right")
            .font(.caption.weight(.semibold))
            .foregroundStyle(.tertiary)
            .accessibilityHidden(true)
        }
        .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      .accessibilityIdentifier("settings.workflows.row.\(entry.id)")
      .accessibilityHint("Show details")
    }
    .padding(.vertical, 2)
    .contextMenu { workflowActions(entry) }
  }

  /// The row's context menu; the detail screen offers the same actions.
  @ViewBuilder
  private func workflowActions(_ entry: WorkflowCatalogEntry) -> some View {
    Button {
      Task { await open(URL(fileURLWithPath: entry.path), projectID: projectID(of: entry)) }
    } label: {
      Label(entry.scope == .bundle ? "View Source" : "Open in Editor", systemImage: "square.and.pencil")
    }
    Button {
      reveal(entry)
    } label: {
      Label("Reveal in Finder", systemImage: "folder")
    }
    Button {
      duplicate(entry)
    } label: {
      Label("Duplicate…", systemImage: "plus.square.on.square")
    }
    .disabled(!entry.isValid)
    if entry.scope != .bundle {
      Divider()
      Button(role: .destructive) {
        trashCandidate = entry
      } label: {
        Label("Move to Trash…", systemImage: "trash")
      }
    }
  }

  private func rowEnabledBinding(for entry: WorkflowCatalogEntry) -> Binding<Bool> {
    Binding(
      get: { !workflows.isDisabled(entry.id) },
      set: { newValue in
        settingsStore.mutateWorkflows { workflows in
          if newValue {
            workflows.disabled.remove(entry.id)
          } else {
            workflows.disabled.insert(entry.id)
          }
        }
      }
    )
  }

  // MARK: - Actions

  private func trust(_ entry: WorkflowCatalogEntry) {
    settingsStore.mutateWorkflows { workflows in
      workflows.trust(path: entry.path, sha256: entry.sha256, at: Date())
    }
    trustPrompt = nil
  }

  private func reveal(_ entry: WorkflowCatalogEntry) {
    NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: entry.path)])
  }

  private func revealUserDirectory() {
    let directory = AppDirectories.workflowsDirectory()
    try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    NSWorkspace.shared.activateFileViewerSelecting([directory])
  }
}

/// Confirmation sheet shown before granting trust to a repository-scoped
/// file with `run:` steps — lists every shell command the file can execute
/// so the user reviews them before agreeing to run them with their own OS
/// permissions (design doc D8).
private struct WorkflowTrustConfirmationSheet: View {
  let entry: WorkflowCatalogEntry
  let onConfirm: () -> Void
  let onCancel: () -> Void

  private var commands: [String] {
    (entry.definition?.flattenedSteps ?? []).compactMap { step in
      guard case .run(let runCommand) = step.verb else { return nil }
      return runCommand.command.source
    }
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      Text("Trust \(entry.name)?")
        .font(.headline)
      Text(
        "This repository-scoped workflow runs shell commands on your machine with your own "
          + "permissions. Review them before trusting this file:"
      )
      .foregroundStyle(.secondary)
      ScrollView {
        VStack(alignment: .leading, spacing: 4) {
          ForEach(Array(commands.enumerated()), id: \.offset) { _, command in
            Text(command)
              .font(.system(.callout, design: .monospaced))
              .textSelection(.enabled)
          }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
      }
      .frame(maxHeight: 160)
      HStack {
        Spacer()
        Button("Cancel", role: .cancel, action: onCancel)
        Button("Trust", action: onConfirm)
          .keyboardShortcut(.defaultAction)
      }
    }
    .padding(20)
    .frame(width: 420)
  }
}

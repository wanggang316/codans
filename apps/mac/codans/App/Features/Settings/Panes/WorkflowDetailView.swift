import AppKit
import CodansCore
import SwiftUI

/// Settings → Workflows → one workflow. The second screen of the pane, in
/// the same shape as an Agent Profile's detail: a grouped `Form` with a
/// window-toolbar back button, swapped in by the parent's local state.
///
/// Everything here reads the watched catalog and `SettingsStore` live, so
/// an edit saved in an editor revalidates on this screen as it happens, and
/// a file removed underneath it turns into an unavailable state instead of
/// a stale form.
struct WorkflowDetailView: View {
  /// `nil` once the file is gone (moved, deleted, renamed on disk).
  let entry: WorkflowCatalogEntry?
  let projectID: ProjectID?
  let onBack: () -> Void
  let onOpen: () -> Void
  let onReveal: () -> Void
  let onDuplicate: () -> Void
  let onTrash: () -> Void
  let onTrust: () -> Void

  @Environment(SettingsStore.self) private var settingsStore
  @Environment(HierarchyManager.self) private var hierarchyManager
  @Environment(WorkflowCatalogStore.self) private var catalog
  @Environment(\.openWindow) private var openWindow

  private var workflows: WorkflowSettings { settingsStore.settings.workflows }
  private var agents: AgentSettings { settingsStore.settings.agents }

  var body: some View {
    Group {
      if let entry {
        form(entry)
      } else {
        ContentUnavailableView(
          "Workflow Unavailable",
          systemImage: "doc.badge.ellipsis",
          description: Text("The file was moved or deleted.")
        )
      }
    }
    .toolbar {
      ToolbarItem(placement: .navigation) {
        Button(action: onBack) {
          Image(systemName: "chevron.backward")
        }
        .help("Back to Workflows")
        .accessibilityLabel("Back to Workflows")
      }
    }
  }

  private func form(_ entry: WorkflowCatalogEntry) -> some View {
    Form {
      header(entry)
      runSection(entry)
      if let definition = entry.definition, !definition.roles.isEmpty {
        rolesSection(entry, definition: definition)
      }
      if let definition = entry.definition, !definition.inputs.isEmpty {
        inputsSection(definition)
      }
      validationSection(entry)
      if entry.requiresTrust {
        trustSection(entry)
      }
      sourceSection(entry)
    }
    .formStyle(.grouped)
  }

  // MARK: - Header

  private func header(_ entry: WorkflowCatalogEntry) -> some View {
    Section {
      HStack(alignment: .top, spacing: 12) {
        Image(systemName: "arrow.triangle.branch")
          .font(.system(size: 22))
          .foregroundStyle(.secondary)
          .frame(width: 28)
          .accessibilityHidden(true)
        VStack(alignment: .leading, spacing: 4) {
          Text(entry.name)
            .font(.headline)
          if let description = entry.definition?.description, !description.isEmpty {
            Text(description)
              .foregroundStyle(.secondary)
              .fixedSize(horizontal: false, vertical: true)
          }
          WorkflowStatusLabel(entry: entry, isDisabled: workflows.isDisabled(entry.id))
            .font(.callout)
        }
      }
      .padding(.vertical, 2)
      LabeledContent("ID") {
        Text(entry.id)
          .font(.body.monospaced())
          .textSelection(.enabled)
      }
      LabeledContent("Scope") {
        Text(Self.scopeTitle(entry.scope, projectName: projectName(projectID)))
      }
      Toggle("Enabled", isOn: enabledBinding(entry))
    }
  }

  private func enabledBinding(_ entry: WorkflowCatalogEntry) -> Binding<Bool> {
    Binding(
      get: { !workflows.isDisabled(entry.id) },
      set: { isOn in
        settingsStore.mutateWorkflows { settings in
          if isOn { settings.disabled.remove(entry.id) } else { settings.disabled.insert(entry.id) }
        }
      })
  }

  static func scopeTitle(_ scope: WorkflowScope, projectName: String?) -> String {
    switch scope {
    case .bundle: return "Built-in · read only"
    case .user: return "User"
    case .repo: return projectName.map { "Repository — \($0)" } ?? "Repository"
    }
  }

  private func projectName(_ id: ProjectID?) -> String? {
    id.flatMap { id in hierarchyManager.catalog.projects.first { $0.id == id }?.name }
  }

  // MARK: - Run

  /// The worktree the main window has selected — where the Run button
  /// starts, the same place the toolbar menu would.
  private var selectedWorktree: (project: Project, worktree: Worktree)? {
    let catalog = hierarchyManager.catalog
    guard
      let projectID = catalog.displayedSelectedProjectID,
      let project = catalog.projects.first(where: { $0.id == projectID }),
      let worktreeID = project.selectedWorktreeID,
      let worktree = project.worktrees.first(where: { $0.id == worktreeID })
    else { return nil }
    return (project, worktree)
  }

  /// Why Run is unavailable, or `nil` when it can start.
  private func runBlocker(_ entry: WorkflowCatalogEntry) -> String? {
    guard workflows.isEnabled else { return "Agent Workflows are turned off." }
    guard entry.isValid else { return "Fix the errors below before running." }
    guard !workflows.isDisabled(entry.id) else { return "This workflow is disabled." }
    guard let selected = selectedWorktree else { return "Select a worktree in the main window first." }
    guard selected.project.remoteHost == nil else { return "Workflows run in local worktrees only." }
    // A run starts by id in the selected worktree; make sure that is this
    // file, so the button never starts something other than what it shows.
    let resolved = catalog.catalog(forWorktreePath: selected.worktree.path).first { $0.id == entry.id }
    guard resolved?.path == entry.path else {
      return "Not available in \(selected.worktree.name). Select the worktree this file belongs to."
    }
    return nil
  }

  private func runSection(_ entry: WorkflowCatalogEntry) -> some View {
    Section {
      let blocker = runBlocker(entry)
      HStack {
        Button {
          catalog.requestRun(workflowID: entry.id)
          openWindow(id: CodansApp.mainWindowID)
        } label: {
          Label(
            selectedWorktree.map { "Run in \($0.worktree.name)" } ?? "Run",
            systemImage: "play.fill")
        }
        .buttonStyle(.borderedProminent)
        .disabled(blocker != nil)
        .accessibilityIdentifier("settings.workflows.detail.run")
        Spacer()
      }
      if let blocker {
        Text(blocker)
          .font(.callout)
          .foregroundStyle(.secondary)
      }
    } header: {
      Text("Run")
    } footer: {
      Text("Opens the start panel in the main window, where roles and inputs are confirmed.")
    }
  }

  // MARK: - Roles

  private func rolesSection(_ entry: WorkflowCatalogEntry, definition: WorkflowDefinition) -> some View {
    Section("Roles") {
      ForEach(definition.roles, id: \.name) { role in
        roleRow(entry, role: role)
      }
    }
  }

  @ViewBuilder
  private func roleRow(_ entry: WorkflowCatalogEntry, role: WorkflowRole) -> some View {
    VStack(alignment: .leading, spacing: 6) {
      HStack(alignment: .firstTextBaseline) {
        Text(role.name)
          .font(.body.monospaced())
        Spacer()
        Text(Self.sourceTitle(role))
          .foregroundStyle(.secondary)
      }
      if let requirement = Self.requirementText(role) {
        Text(requirement)
          .font(.caption)
          .foregroundStyle(.secondary)
      }
      if role.source == .launch {
        preferredProfilePicker(entry, role: role)
      }
    }
    .padding(.vertical, 2)
  }

  static func sourceTitle(_ role: WorkflowRole) -> String {
    switch role.source {
    case .current: return "The pane that starts the run"
    case .launch: return "Launched for the run"
    case .pick: return "An agent pane you choose"
    }
  }

  static func requirementText(_ role: WorkflowRole) -> String? {
    var parts: [String] = []
    if let kinds = role.agents, !kinds.isEmpty {
      parts.append("Agents: " + kinds.map(\.displayName).joined(separator: ", "))
    }
    if let profile = role.profile {
      parts.append("Suggested profile: \(profile)")
    }
    return parts.isEmpty ? nil : parts.joined(separator: " · ")
  }

  /// The remembered binding admission would use. "Automatic" forgets it and
  /// falls back to the file's `profile:` hint or the single qualifying
  /// profile — the same order the start panel prefills from.
  private func preferredProfilePicker(_ entry: WorkflowCatalogEntry, role: WorkflowRole) -> some View {
    let digest = WorkflowAdmission.requirementsDigest(for: role)
    let candidates = WorkflowAdmission.candidateProfiles(for: role, in: agents)
    let remembered = workflows.binding(scope: entry.scope, workflowID: entry.id, role: role.name, digest: digest)
    let selection = Binding<UUID?>(
      get: { remembered?.profileID },
      set: { profileID in
        settingsStore.mutateWorkflows { settings in
          if let profileID {
            settings.remember(
              WorkflowBindingMemory(
                scope: entry.scope, workflowID: entry.id, role: role.name,
                requirementsDigest: digest, profileID: profileID))
          } else {
            settings.forgetBinding(scope: entry.scope, workflowID: entry.id, role: role.name)
          }
        }
      })
    return Picker("Preferred profile", selection: selection) {
      Text("Automatic").tag(UUID?.none)
      if !candidates.isEmpty {
        Divider()
      }
      ForEach(candidates, id: \.id) { profile in
        Text(profile.displayName).tag(UUID?.some(profile.id))
      }
    }
    .disabled(candidates.isEmpty)
    .help(candidates.isEmpty ? "No enabled Agent Profile can play this role." : "Used when the run starts")
  }

  // MARK: - Inputs

  private func inputsSection(_ definition: WorkflowDefinition) -> some View {
    Section("Inputs") {
      ForEach(definition.inputs, id: \.name) { input in
        VStack(alignment: .leading, spacing: 2) {
          HStack(alignment: .firstTextBaseline) {
            Text(input.name)
              .font(.body.monospaced())
            Spacer()
            Text(Self.inputSummary(input))
              .foregroundStyle(.secondary)
          }
          if let description = input.description, !description.isEmpty {
            Text(description)
              .font(.caption)
              .foregroundStyle(.secondary)
          }
        }
        .padding(.vertical, 2)
      }
    }
  }

  static func inputSummary(_ input: WorkflowInput) -> String {
    var parts = [input.kind.rawValue]
    if input.isRequired {
      parts.append("required")
    } else if let text = input.defaultValue?.interpolatedText, !text.isEmpty {
      parts.append("default \(text)")
    }
    return parts.joined(separator: " · ")
  }

  // MARK: - Validation

  private func validationSection(_ entry: WorkflowCatalogEntry) -> some View {
    Section {
      if entry.diagnostics.isEmpty {
        Label("No problems found", systemImage: "checkmark.circle.fill")
          .foregroundStyle(.green)
      } else {
        ForEach(Array(entry.diagnostics.enumerated()), id: \.offset) { _, diagnostic in
          HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: diagnostic.isError ? "xmark.octagon.fill" : "exclamationmark.triangle.fill")
              .foregroundStyle(diagnostic.isError ? .red : .orange)
              .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
              Text(diagnostic.message)
                .fixedSize(horizontal: false, vertical: true)
              Text([diagnostic.path, diagnostic.code].compactMap { $0 }.joined(separator: " · "))
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
            }
          }
        }
      }
    } header: {
      Text("Validation")
    } footer: {
      Text("Revalidated automatically whenever the file changes.")
    }
  }

  // MARK: - Trust

  @ViewBuilder
  private func trustSection(_ entry: WorkflowCatalogEntry) -> some View {
    Section {
      switch WorkflowsSettingsLogic.TrustState.resolve(entry: entry, workflows: workflows) {
      case .notRequired:
        EmptyView()
      case .trusted(let grantedAt):
        HStack {
          Label(
            "Trusted \(grantedAt.formatted(date: .abbreviated, time: .omitted))",
            systemImage: "checkmark.shield.fill"
          )
          .foregroundStyle(.green)
          Spacer()
          Button("Revoke") {
            settingsStore.mutateWorkflows { $0.revokeTrust(path: entry.path) }
          }
        }
      case .outdated:
        HStack {
          Label("The file changed since you trusted it", systemImage: "exclamationmark.shield.fill")
            .foregroundStyle(.orange)
          Spacer()
          Button("Review and Trust…", action: onTrust)
        }
      case .notTrusted:
        HStack {
          Label("Not trusted yet", systemImage: "shield.slash")
            .foregroundStyle(.secondary)
          Spacer()
          Button("Review and Trust…", action: onTrust)
        }
      }
    } header: {
      Text("Shell Commands")
    } footer: {
      Text("This repository file runs shell commands. It starts only after you review and trust this exact version.")
    }
  }

  // MARK: - Source

  private func sourceSection(_ entry: WorkflowCatalogEntry) -> some View {
    Section("Source File") {
      LabeledContent("Path") {
        Text((entry.path as NSString).abbreviatingWithTildeInPath)
          .font(.callout.monospaced())
          .lineLimit(1)
          .truncationMode(.middle)
          .textSelection(.enabled)
          .help(entry.path)
      }
      HStack(spacing: 8) {
        Button(entry.scope == .bundle ? "View Source" : "Open in Editor", action: onOpen)
        Button("Reveal in Finder", action: onReveal)
        Button("Duplicate…", action: onDuplicate)
          .disabled(!entry.isValid)
        Spacer()
        if entry.scope != .bundle {
          Button("Move to Trash…", role: .destructive, action: onTrash)
        }
      }
    }
  }
}

/// "Ready", "Ready · 2 warnings", "Invalid · 1 error", "Disabled" — the
/// status the list row and the detail header both show.
struct WorkflowStatusLabel: View {
  let entry: WorkflowCatalogEntry
  let isDisabled: Bool

  var body: some View {
    let (text, symbol, color) = presentation
    Label(text, systemImage: symbol)
      .foregroundStyle(color)
      .labelStyle(.titleAndIcon)
  }

  private var presentation: (String, String, Color) {
    switch WorkflowsSettingsLogic.RowStatus(diagnostics: entry.diagnostics) {
    case .errors(let count):
      return ("Invalid · \(count) error\(count == 1 ? "" : "s")", "xmark.octagon.fill", .red)
    case .warnings(let count) where !isDisabled:
      return ("Ready · \(count) warning\(count == 1 ? "" : "s")", "exclamationmark.triangle.fill", .orange)
    case .ok where !isDisabled, .warnings where !isDisabled:
      return ("Ready", "checkmark.circle.fill", .green)
    default:
      return ("Disabled", "pause.circle.fill", .secondary)
    }
  }
}

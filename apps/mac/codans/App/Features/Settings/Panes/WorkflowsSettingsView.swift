import AppKit
import CodansCore
import SwiftUI

/// Settings → Agents → Workflows. Lists every discovered
/// `<id>.workflow.yaml` across the three scopes (bundle, user, one section
/// per repository), with an enable switch, live diagnostics, remembered
/// `launch` role bindings, and repository-file trust — the Settings surface
/// `docs/design-docs/workflow.md` describes under "可观测性与 UI".
///
/// Discovery is a plain filesystem scan (`WorkflowDiscovery`, which caches
/// nothing by design) run off the main thread on appear and on demand via
/// the refresh button; the pane owns no long-lived state beyond the last
/// scan's results.
struct WorkflowsSettingsView: View {
  @Environment(SettingsStore.self) private var settingsStore
  @Environment(HierarchyManager.self) private var hierarchyManager

  @State private var scanResult = ScanResult()
  @State private var isScanning = false
  @State private var trustPrompt: TrustPromptTarget?

  private struct ScanResult: Sendable {
    var bundle: [WorkflowCatalogEntry] = []
    var user: [WorkflowCatalogEntry] = []
    var repositories: [ProjectID: [WorkflowCatalogEntry]] = [:]
  }

  private struct TrustPromptTarget: Identifiable {
    let entry: WorkflowCatalogEntry
    var id: String { entry.path }
  }

  private var workflows: WorkflowSettings { settingsStore.settings.workflows }
  private var agents: AgentSettings { settingsStore.settings.agents }

  private var eligibleProjects: [Project] {
    WorkflowsSettingsLogic.eligibleRepositoryProjects(hierarchyManager.catalog.projects)
  }

  private var repositoryGroups: [WorkflowsSettingsLogic.RepositoryGroup] {
    WorkflowsSettingsLogic.repositoryGroups(eligibleProjects: eligibleProjects, scanned: scanResult.repositories)
  }

  var body: some View {
    Form {
      masterSection
      scopeSection(title: "Built-in", entries: scanResult.bundle, emptyText: "No built-in workflows.")
      userScopeSection
      ForEach(repositoryGroups) { group in
        scopeSection(title: "Repository — \(group.projectName)", entries: group.entries, emptyText: "")
      }
    }
    .formStyle(.grouped)
    .task { await refresh() }
    .sheet(item: $trustPrompt) { target in
      WorkflowTrustConfirmationSheet(
        entry: target.entry,
        onConfirm: { trust(target.entry) },
        onCancel: { trustPrompt = nil }
      )
    }
  }

  // MARK: - Master

  private var masterSection: some View {
    Section {
      HStack {
        Toggle("Enable Agent Workflows", isOn: enabledBinding)
        Spacer()
        if isScanning {
          ProgressView()
            .controlSize(.small)
        }
        Button {
          Task { await refresh() }
        } label: {
          Image(systemName: "arrow.clockwise")
        }
        .buttonStyle(.borderless)
        .help("Rescan workflow files")
        .disabled(isScanning)
      }
    } footer: {
      Text("Turning this off removes the `codans workflow` commands and palette entries.")
    }
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
      if scanResult.user.isEmpty {
        Text("No workflows in ~/.codans/workflows yet.")
          .foregroundStyle(.secondary)
      } else {
        ForEach(scanResult.user, id: \.id) { entry in
          workflowRow(entry)
        }
      }
    }
  }

  private var userDirectoryDisplayPath: String {
    (AppDirectories.workflowsDirectory().path(percentEncoded: false) as NSString).abbreviatingWithTildeInPath
  }

  // MARK: - Row

  @ViewBuilder
  private func workflowRow(_ entry: WorkflowCatalogEntry) -> some View {
    DisclosureGroup {
      workflowDetail(entry)
    } label: {
      HStack(spacing: 8) {
        Toggle(isOn: rowEnabledBinding(for: entry)) {
          EmptyView()
        }
        .labelsHidden()
        .toggleStyle(.checkbox)
        .accessibilityLabel("Enable \(entry.name)")

        VStack(alignment: .leading, spacing: 2) {
          Text(entry.name)
            .lineLimit(1)
          Text("\(entry.id) · \((entry.path as NSString).lastPathComponent)")
            .font(.caption)
            .foregroundStyle(.secondary)
            .lineLimit(1)
        }
        Spacer()
        statusGlyph(for: entry)
      }
      .padding(.vertical, 2)
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

  @ViewBuilder
  private func statusGlyph(for entry: WorkflowCatalogEntry) -> some View {
    switch WorkflowsSettingsLogic.RowStatus(diagnostics: entry.diagnostics) {
    case .ok:
      Image(systemName: "checkmark.circle.fill")
        .foregroundStyle(.green)
        .help("No diagnostics")
    case .warnings(let count):
      Label("\(count)", systemImage: "exclamationmark.triangle.fill")
        .foregroundStyle(.orange)
        .help("\(count) warning(s)")
    case .errors(let count):
      Label("\(count)", systemImage: "exclamationmark.octagon.fill")
        .foregroundStyle(.red)
        .help("\(count) error(s) — this workflow cannot start")
    }
  }

  // MARK: - Detail

  @ViewBuilder
  private func workflowDetail(_ entry: WorkflowCatalogEntry) -> some View {
    VStack(alignment: .leading, spacing: 10) {
      if !entry.diagnostics.isEmpty {
        VStack(alignment: .leading, spacing: 6) {
          ForEach(Array(entry.diagnostics.enumerated()), id: \.offset) { _, diagnostic in
            diagnosticRow(diagnostic)
          }
        }
      }

      let bindings = WorkflowsSettingsLogic.roleBindings(for: entry, workflows: workflows, agents: agents)
      if !bindings.isEmpty {
        VStack(alignment: .leading, spacing: 4) {
          ForEach(bindings) { binding in
            roleBindingRow(entry: entry, binding: binding)
          }
        }
      }

      if entry.requiresTrust {
        trustRow(entry)
      }

      HStack {
        Spacer()
        Button {
          reveal(entry)
        } label: {
          Label("Reveal", systemImage: "folder")
        }
        .buttonStyle(.borderless)
      }
    }
    .padding(.leading, 24)
    .padding(.vertical, 4)
  }

  private func diagnosticRow(_ diagnostic: WorkflowDiagnostic) -> some View {
    HStack(alignment: .firstTextBaseline, spacing: 6) {
      Image(systemName: diagnostic.isError ? "xmark.circle.fill" : "exclamationmark.triangle.fill")
        .foregroundStyle(diagnostic.isError ? .red : .orange)
        .accessibilityHidden(true)
      VStack(alignment: .leading, spacing: 1) {
        Text("\(diagnostic.severity.rawValue) \(diagnostic.code): \(diagnostic.message)")
          .font(.callout)
        if let path = diagnostic.path {
          Text(path)
            .font(.caption)
            .foregroundStyle(.secondary)
        }
      }
    }
  }

  private func roleBindingRow(entry: WorkflowCatalogEntry, binding: WorkflowsSettingsLogic.RoleBinding) -> some View {
    HStack {
      Text(binding.role.name)
        .font(.callout.weight(.medium))
      Text(binding.profileName ?? "not remembered")
        .font(.callout)
        .foregroundStyle(binding.isRemembered ? .primary : .secondary)
      Spacer()
      if binding.isRemembered {
        Button("Forget") {
          forget(entry: entry, role: binding.role.name)
        }
        .buttonStyle(.borderless)
      }
    }
  }

  @ViewBuilder
  private func trustRow(_ entry: WorkflowCatalogEntry) -> some View {
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
          revokeTrust(entry)
        }
        .buttonStyle(.borderless)
      }
    case .outdated(let grantedAt):
      HStack {
        Label("Trust outdated — file changed", systemImage: "exclamationmark.shield.fill")
          .foregroundStyle(.orange)
          .help("Granted \(grantedAt.formatted(date: .abbreviated, time: .omitted))")
        Spacer()
        Button("Trust…") {
          trustPrompt = TrustPromptTarget(entry: entry)
        }
        .buttonStyle(.borderless)
      }
    case .notTrusted:
      HStack {
        Label("Not trusted", systemImage: "shield.slash")
          .foregroundStyle(.secondary)
        Spacer()
        Button("Trust…") {
          trustPrompt = TrustPromptTarget(entry: entry)
        }
        .buttonStyle(.borderless)
      }
    }
  }

  // MARK: - Actions

  private func forget(entry: WorkflowCatalogEntry, role: String) {
    settingsStore.mutateWorkflows { workflows in
      workflows.forgetBinding(scope: entry.scope, workflowID: entry.id, role: role)
    }
  }

  private func trust(_ entry: WorkflowCatalogEntry) {
    settingsStore.mutateWorkflows { workflows in
      workflows.trust(path: entry.path, sha256: entry.sha256, at: Date())
    }
    trustPrompt = nil
  }

  private func revokeTrust(_ entry: WorkflowCatalogEntry) {
    settingsStore.mutateWorkflows { workflows in
      workflows.revokeTrust(path: entry.path)
    }
  }

  private func reveal(_ entry: WorkflowCatalogEntry) {
    NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: entry.path)])
  }

  private func revealUserDirectory() {
    let directory = AppDirectories.workflowsDirectory()
    try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    NSWorkspace.shared.activateFileViewerSelecting([directory])
  }

  // MARK: - Discovery

  /// Rescans all three scopes off the main thread. `WorkflowDiscovery` is a
  /// pure, cacheless filesystem reader (see its doc comment), so a fresh
  /// scan per appearance / refresh is the intended usage rather than
  /// something to optimize away.
  private func refresh() async {
    isScanning = true
    defer { isScanning = false }
    let projects = eligibleProjects
    let bundleDirectory = Bundle.main.resourceURL?.appendingPathComponent("workflows", isDirectory: true)
    let userDirectory = AppDirectories.workflowsDirectory()
    scanResult = await Task.detached(priority: .userInitiated) { () -> ScanResult in
      var result = ScanResult()
      if let bundleDirectory {
        result.bundle = WorkflowDiscovery.scan(directory: bundleDirectory, scope: .bundle)
      }
      result.user = WorkflowDiscovery.scan(directory: userDirectory, scope: .user)
      for project in projects {
        let directory = WorkflowDiscovery.repositoryDirectory(
          worktreeRoot: URL(fileURLWithPath: project.rootPath, isDirectory: true))
        result.repositories[project.id] = WorkflowDiscovery.scan(directory: directory, scope: .repo)
      }
      return result
    }.value
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

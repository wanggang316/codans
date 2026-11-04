import AppKit
import CodansCore
import ComposableArchitecture
import SwiftUI

/// "Code Hosts" section of the Settings window (ADR 0004 item 10):
///   - One block per Code Host: the availability of its CLI (`gh`, `glab`), the host and
///     user it is logged in as, Re-check, and a docs link. Probed on appear and on
///     Re-check through the `CodeHostClient` dependency.
///   - Code Host aliases (ADR 0005): remote host → kind and API host, with add, edit,
///     delete, and whether the CLI of the kind is logged in to the API host. Written
///     through `SettingsStore.mutateGeneral`; `GeneralSettings.saveCodeHostAlias` keeps
///     the remote host unique.
///   - Defaults that apply to every Code Host: merge strategy and post-merge Worktree
///     action, written through `SettingsStore.mutateGeneral`.
///
/// A Code Host serves repositories; the "Hosts" pane lists machines (ADR 0003). The pane
/// text names both so the two are not confused.
///
/// The Settings window is a separate scene with its own TCA store, so this view keeps its
/// own availability state instead of sharing RootFeature's `CodeHostFeature` store.
struct CodeHostsSettingsView: View {
  let settingsStore: SettingsStore

  @Dependency(CodeHostClient.self) private var codeHost
  @State private var availability: [CodeHostKind: CodeHostAvailability] = [:]
  @State private var checking: Set<CodeHostKind> = []
  /// Hosts each CLI is logged in to; absent while it is asked.
  @State private var loggedInHosts: [CodeHostKind: Set<String>] = [:]
  @State private var aliasEditor: AliasDraft?

  var body: some View {
    Form {
      Section {
        Text(
          "codans reads pull requests and merge requests through the CLI of each Code Host. "
            + "A Project uses the Code Host of its origin remote; add a Code Host alias "
            + "when neither CLI knows the host. Machines that run Projects are in Hosts."
        )
        .font(.callout)
        .foregroundStyle(.secondary)
      }

      ForEach(CodeHostKind.allCases, id: \.self) { kind in
        Section(kind.displayName) {
          availabilityRow(kind)
          HStack {
            Button("Re-check") {
              Task {
                await codeHost.invalidateResolution()
                await probe(kind)
              }
            }
            .disabled(checking.contains(kind))
            Button("Open \(kind.cliName) docs") {
              if let url = Self.docsURL(kind) {
                NSWorkspace.shared.open(url)
              }
            }
          }
        }
      }

      aliasesSection

      Section {
        Picker("Default merge strategy", selection: mergeStrategyBinding) {
          Text("Default (\(MergeStrategy.squash.displayName))").tag(MergeStrategy?.none)
          ForEach(MergeStrategy.allCases, id: \.self) { strategy in
            Text(strategy.displayName).tag(Optional(strategy))
          }
        }

        Picker("After merging", selection: postMergeActionBinding) {
          Text("Ask each time").tag(MergedWorktreeAction?.none)
          ForEach(MergedWorktreeAction.allCases.filter { $0 != .ask }, id: \.self) { action in
            Text(action.displayName).tag(Optional(action))
          }
        }
      } header: {
        Text("Defaults")
      } footer: {
        Text(
          "These apply to GitHub and GitLab. On GitLab, the project's merge method applies, "
            + "and \(MergeStrategy.rebase.displayName) uses Merge."
        )
        .font(.footnote)
        .foregroundStyle(.secondary)
      }
    }
    .formStyle(.grouped)
    .sheet(item: $aliasEditor) { draft in
      CodeHostAliasEditorSheet(draft: draft, save: saveAlias) { aliasEditor = nil }
    }
    .task {
      await withTaskGroup(of: Void.self) { group in
        for kind in CodeHostKind.allCases {
          group.addTask { await probe(kind) }
        }
      }
    }
  }

  static func docsURL(_ kind: CodeHostKind) -> URL? {
    switch kind {
    case .github: return URL(string: "https://cli.github.com/manual/")
    case .gitlab: return URL(string: "https://docs.gitlab.com/cli/")
    }
  }

  @ViewBuilder
  private func availabilityRow(_ kind: CodeHostKind) -> some View {
    switch availability[kind] ?? .unknown {
    case .available(let host, let user):
      HStack {
        Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
          .accessibilityHidden(true)
        Text(
          user.isEmpty ? "\(kind.cliName): connected to \(host)" : "\(kind.cliName): connected to \(host) as @\(user)")
      }
    case .unavailable(let reason):
      HStack(alignment: .top) {
        Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.yellow)
          .accessibilityHidden(true)
        VStack(alignment: .leading, spacing: 4) {
          Text(reason)
            .multilineTextAlignment(.leading)
          let install = "brew install \(kind.cliName)"
          if reason.contains(install) {
            Button("Copy `\(install)`") {
              NSPasteboard.general.clearContents()
              NSPasteboard.general.setString(install, forType: .string)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
          }
        }
      }
    case .unknown:
      HStack {
        ProgressView().controlSize(.small)
        Text("Checking \(kind.cliDisplayName)…")
      }
    }
  }

  private func probe(_ kind: CodeHostKind) async {
    checking.insert(kind)
    availability[kind] = .unknown
    loggedInHosts[kind] = nil
    availability[kind] = await codeHost.availability(kind)
    loggedInHosts[kind] = Set(await codeHost.authenticatedHosts(kind).map { $0.lowercased() })
    checking.remove(kind)
  }

  // MARK: - Code Host aliases

  private var aliases: [CodeHostAlias] {
    settingsStore.settings.general.codeHostAliases
  }

  @ViewBuilder
  private var aliasesSection: some View {
    Section {
      if aliases.isEmpty {
        Text("No aliases.")
          .foregroundStyle(.secondary)
      }
      ForEach(aliases) { alias in
        aliasRow(alias)
      }
      Button {
        aliasEditor = AliasDraft(alias: nil)
      } label: {
        Label("Add Alias…", systemImage: "plus")
      }
      .buttonStyle(.borderless)
    } header: {
      Text("Code Host aliases")
    } footer: {
      Text(
        "An alias gives the Code Host and API host of a remote host that neither CLI knows, "
          + "for example an SSH host name that is not the API host. It applies to every Project "
          + "whose origin has that host, and it comes before the CLI hosts."
      )
      .font(.footnote)
      .foregroundStyle(.secondary)
    }
  }

  private func aliasRow(_ alias: CodeHostAlias) -> some View {
    HStack(alignment: .top, spacing: 10) {
      VStack(alignment: .leading, spacing: 4) {
        Text("\(alias.remoteHost) → \(alias.kind.displayName), \(alias.apiHost)")
          .lineLimit(1)
          .truncationMode(.middle)
        aliasStatusView(Self.aliasStatus(alias, loggedInHosts: loggedInHosts[alias.kind]))
      }
      Spacer(minLength: 12)
      Button {
        aliasEditor = AliasDraft(alias: alias)
      } label: {
        Image(systemName: "pencil")
          .accessibilityLabel("Edit alias \(alias.remoteHost)")
      }
      .buttonStyle(.borderless)
      .help("Edit alias")
      Button {
        settingsStore.mutateGeneral { $0.removeCodeHostAlias(id: alias.id) }
      } label: {
        Image(systemName: "trash")
          .accessibilityLabel("Delete alias \(alias.remoteHost)")
      }
      .buttonStyle(.borderless)
      .help("Delete alias")
    }
  }

  @ViewBuilder
  private func aliasStatusView(_ status: AliasStatus) -> some View {
    switch status {
    case .checking:
      HStack(spacing: 6) {
        ProgressView().controlSize(.mini)
        Text("Checking…")
      }
      .font(.caption)
      .foregroundStyle(.secondary)
    case .loggedIn(let cliName):
      Label("\(cliName) is logged in", systemImage: "checkmark.circle.fill")
        .font(.caption)
        .foregroundStyle(.secondary)
    case .notLoggedIn(let message):
      Label(message, systemImage: "exclamationmark.triangle.fill")
        .font(.caption)
        .foregroundStyle(.secondary)
        .textSelection(.enabled)
    }
  }

  nonisolated enum AliasStatus: Equatable {
    case checking
    case loggedIn(cliName: String)
    /// The message the badge position shows for a missing login.
    case notLoggedIn(message: String)
  }

  /// Whether the CLI of the alias's kind is logged in to its API host. `loggedInHosts`
  /// is `nil` while the CLI is asked.
  nonisolated static func aliasStatus(_ alias: CodeHostAlias, loggedInHosts: Set<String>?) -> AliasStatus {
    guard let loggedInHosts else { return .checking }
    if loggedInHosts.contains(alias.apiHost) { return .loggedIn(cliName: alias.kind.cliName) }
    return .notLoggedIn(message: CodeHostError.notAuthenticated(alias.kind, host: alias.apiHost).userFacingMessage)
  }

  /// Saves the alias, or returns the message that says why it cannot be saved.
  private func saveAlias(_ alias: CodeHostAlias) -> String? {
    var general = settingsStore.settings.general
    do {
      try general.saveCodeHostAlias(alias)
    } catch {
      return error.message
    }
    settingsStore.mutateGeneral { $0.codeHostAliases = general.codeHostAliases }
    return nil
  }

  // MARK: - Bindings

  private var mergeStrategyBinding: Binding<MergeStrategy?> {
    Binding(
      get: { settingsStore.settings.general.defaultMergeStrategy },
      set: { newValue in
        settingsStore.mutateGeneral { $0.defaultMergeStrategy = newValue }
      }
    )
  }

  private var postMergeActionBinding: Binding<MergedWorktreeAction?> {
    Binding(
      get: { settingsStore.settings.general.postMergeAction },
      set: { newValue in
        settingsStore.mutateGeneral { $0.postMergeAction = newValue }
      }
    )
  }
}

/// The alias the editor sheet opens with: an existing alias, or a new one.
struct AliasDraft: Identifiable {
  let id = UUID()
  let alias: CodeHostAlias?
}

/// Add / edit form for one Code Host alias.
private struct CodeHostAliasEditorSheet: View {
  let draft: AliasDraft
  let save: (CodeHostAlias) -> String?
  let dismiss: () -> Void

  @State private var remoteHost = ""
  @State private var kind: CodeHostKind = .gitlab
  @State private var apiHost = ""
  @State private var errorMessage: String?

  private var isEditing: Bool { draft.alias != nil }

  var body: some View {
    VStack(alignment: .leading, spacing: 14) {
      Text(isEditing ? "Edit Code Host Alias" : "Add Code Host Alias")
        .font(.headline)

      if let errorMessage {
        Text(errorMessage)
          .font(.caption)
          .foregroundStyle(.red)
          .textSelection(.enabled)
          .frame(maxWidth: .infinity, alignment: .leading)
      }

      Form {
        TextField("Remote host", text: $remoteHost, prompt: Text("ssh.gitlab.example.com"))
        Picker("Code Host", selection: $kind) {
          ForEach(CodeHostKind.allCases, id: \.self) { kind in
            Text(kind.displayName).tag(kind)
          }
        }
        TextField("API host", text: $apiHost, prompt: Text("gitlab.example.com"))
      }
      .formStyle(.columns)

      Text(
        "Remote host: the host in the origin URL. API host: the host \(kind.cliName) is logged in to, "
          + "with its port when it has one."
      )
      .font(.caption)
      .foregroundStyle(.secondary)
      .fixedSize(horizontal: false, vertical: true)

      HStack {
        Spacer()
        Button("Cancel", action: dismiss)
          .keyboardShortcut(.cancelAction)
        Button(isEditing ? "Save" : "Add") {
          let alias = CodeHostAlias(
            id: draft.alias?.id ?? UUID(), remoteHost: remoteHost, kind: kind, apiHost: apiHost)
          if let message = save(alias) {
            errorMessage = message
          } else {
            dismiss()
          }
        }
        .keyboardShortcut(.defaultAction)
        .disabled(
          remoteHost.trimmingCharacters(in: .whitespaces).isEmpty
            || apiHost.trimmingCharacters(in: .whitespaces).isEmpty)
      }
    }
    .padding(20)
    .frame(width: 420)
    .onAppear {
      guard let alias = draft.alias else { return }
      remoteHost = alias.remoteHost
      kind = alias.kind
      apiHost = alias.apiHost
    }
  }
}

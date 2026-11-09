import AppKit
import CodansCore
import ComposableArchitecture
import SwiftUI

/// "Git Platforms" section of the Settings window (ADR 0004 item 10):
///   - One section per Git Platform: its official mark (a template image), the status of
///     its CLI (`gh`, `glab`) with the install or `auth login` command when one is
///     missing, Re-check, a docs link, and the capability list from
///     `GitPlatformKind.capabilities`. Probed on appear and on Re-check through the
///     `GitPlatformClient` dependency.
///   - Git Platform aliases (ADR 0005): remote host → kind and API host, with add, edit,
///     delete, and whether the CLI of the kind is logged in to the API host. Written
///     through `SettingsStore.mutateGeneral`; `GeneralSettings.saveGitPlatformAlias` keeps
///     the remote host unique.
///   - Defaults that apply to every Git Platform: merge strategy and post-merge Worktree
///     action, written through `SettingsStore.mutateGeneral`.
///
/// A Git Platform serves repositories; the "Remote Hosts" pane lists machines (ADR 0003). A
/// footer note names both so the two are not confused.
///
/// The Settings window is a separate scene with its own TCA store, so this view keeps its
/// own availability state instead of sharing RootFeature's `GitPlatformFeature` store.
struct GitPlatformsSettingsView: View {
  let settingsStore: SettingsStore

  @Dependency(GitPlatformClient.self) private var gitPlatform
  @State private var availability: [GitPlatformKind: GitPlatformAvailability] = [:]
  @State private var checking: Set<GitPlatformKind> = []
  /// Hosts each CLI is logged in to; absent while it is asked.
  @State private var loggedInHosts: [GitPlatformKind: Set<String>] = [:]
  @State private var aliasEditor: AliasDraft?

  var body: some View {
    Form {
      Section {
        Text("codans reads Pull Requests through the CLI of each Git Platform.")
          .foregroundStyle(.secondary)
      }

      ForEach(GitPlatformKind.allCases, id: \.self) { kind in
        Section {
          platformRow(kind)
          capabilityList(kind)
        }
      }

      aliasesSection

      Section {
        Picker(selection: mergeStrategyBinding) {
          Text("Default (\(MergeStrategy.squash.displayName))").tag(MergeStrategy?.none)
          ForEach(MergeStrategy.allCases, id: \.self) { strategy in
            Text(strategy.displayName).tag(Optional(strategy))
          }
        } label: {
          Text("Default merge strategy")
          Text(
            "Applies to GitHub and GitLab. On GitLab, the project's merge method applies, "
              + "and \(MergeStrategy.rebase.displayName) uses Merge.")
        }

        Picker(selection: postMergeActionBinding) {
          Text("Ask each time").tag(MergedWorktreeAction?.none)
          ForEach(MergedWorktreeAction.allCases.filter { $0 != .ask }, id: \.self) { action in
            Text(action.displayName).tag(Optional(action))
          }
        } label: {
          Text("After merging")
          Text("What codans does with the Worktree of a merged Pull Request.")
        }
      } header: {
        Text("Defaults")
      } footer: {
        Text("A Git Platform serves repositories. Machines that run Projects are in Remote Hosts.")
          .font(.footnote)
          .foregroundStyle(.secondary)
      }
    }
    .formStyle(.grouped)
    .sheet(item: $aliasEditor) { draft in
      GitPlatformAliasEditorSheet(draft: draft, save: saveAlias) { aliasEditor = nil }
    }
    .task {
      await withTaskGroup(of: Void.self) { group in
        for kind in GitPlatformKind.allCases {
          group.addTask { await probe(kind) }
        }
      }
    }
  }

  static func docsURL(_ kind: GitPlatformKind) -> URL? {
    switch kind {
    case .github: return URL(string: "https://cli.github.com/manual/")
    case .gitlab: return URL(string: "https://docs.gitlab.com/cli/")
    }
  }

  /// Asset name of the official mark of the Git Platform. The asset sets its rendering:
  /// GitHub's one-color mark is a template image; GitLab's tanuki keeps its own colors.
  static func markImageName(_ kind: GitPlatformKind) -> String {
    switch kind {
    case .github: return "github-mark"
    case .gitlab: return "gitlab-mark"
    }
  }

  /// Warning text of a missing CLI. It names only what is missing; the install command
  /// shows on its own row so the text and the copy action stay separate.
  static func notInstalledMessage(_ kind: GitPlatformKind) -> String {
    "\(kind.cliDisplayName) (\(kind.cliName)) is not installed."
  }

  /// Warning text of a CLI that is not logged in. The `auth login` command shows on its
  /// own row, as the install command does.
  static func notLoggedInMessage(_ kind: GitPlatformKind, host: String?) -> String {
    "\(kind.cliName) is not logged in to \(host ?? kind.displayName)."
  }

  /// The mark, the name, and the CLI status, with Re-check and the docs link at the end.
  private func platformRow(_ kind: GitPlatformKind) -> some View {
    HStack(alignment: .top, spacing: 10) {
      Image(Self.markImageName(kind))
        .resizable()
        .scaledToFit()
        .frame(width: 24, height: 24)
        .foregroundStyle(.primary)
        .accessibilityHidden(true)
      VStack(alignment: .leading, spacing: 4) {
        Text(kind.displayName)
          .font(.headline)
        availabilityView(kind)
      }
      Spacer(minLength: 12)
      Button("Re-check") {
        Task {
          await gitPlatform.invalidateResolution()
          await probe(kind)
        }
      }
      .disabled(checking.contains(kind))
      HelpLink {
        if let url = Self.docsURL(kind) {
          NSWorkspace.shared.open(url)
        }
      }
      .help("Open \(kind.cliName) docs")
      .accessibilityLabel("Open \(kind.cliName) docs")
    }
  }

  @ViewBuilder
  private func availabilityView(_ kind: GitPlatformKind) -> some View {
    switch availability[kind] ?? .unknown {
    case .available(let host, let user):
      Label {
        Text(user.isEmpty ? "\(kind.cliName) connected to \(host)" : "\(kind.cliName) connected to \(host) as @\(user)")
      } icon: {
        Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
      }
      .font(.callout)
    case .notInstalled:
      warning(Self.notInstalledMessage(kind), command: kind.installCommand, copyLabel: "Copy install command")
    case .notLoggedIn(let host):
      warning(
        Self.notLoggedInMessage(kind, host: host), command: kind.loginCommand(host: host),
        copyLabel: "Copy login command")
    case .unavailable(let reason):
      warning(reason, command: nil, copyLabel: "")
    case .unknown:
      HStack(spacing: 6) {
        ProgressView().controlSize(.small)
        Text("Checking \(kind.cliDisplayName)…")
      }
      .font(.callout)
      .foregroundStyle(.secondary)
    }
  }

  private func warning(_ message: String, command: String?, copyLabel: String) -> some View {
    VStack(alignment: .leading, spacing: 6) {
      Label {
        Text(message)
          .multilineTextAlignment(.leading)
          .textSelection(.enabled)
      } icon: {
        Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.yellow)
      }
      .font(.callout)
      if let command {
        CLIInstallCommandRow(command: command, copyLabel: copyLabel)
      }
    }
  }

  /// What codans can do with the Git Platform. An unsupported item is dimmed and says why.
  private func capabilityList(_ kind: GitPlatformKind) -> some View {
    VStack(alignment: .leading, spacing: 6) {
      ForEach(kind.capabilities) { capability in
        HStack(alignment: .firstTextBaseline, spacing: 6) {
          Image(systemName: capability.isSupported ? "checkmark" : "minus")
            .font(.caption.weight(.semibold))
            .foregroundStyle(capability.isSupported ? AnyShapeStyle(.green) : AnyShapeStyle(.tertiary))
            .frame(width: 14)
            .accessibilityHidden(true)
          Text(capability.title)
            .foregroundStyle(capability.isSupported ? .primary : .secondary)
          if let reason = capability.unsupportedReason {
            Text("— \(reason)")
              .foregroundStyle(.secondary)
          }
        }
        .font(.callout)
        .accessibilityElement(children: .combine)
      }
    }
    .padding(.leading, 34)
  }

  private func probe(_ kind: GitPlatformKind) async {
    checking.insert(kind)
    availability[kind] = .unknown
    loggedInHosts[kind] = nil
    availability[kind] = await gitPlatform.availability(kind)
    loggedInHosts[kind] = Set(await gitPlatform.authenticatedHosts(kind).map { $0.lowercased() })
    checking.remove(kind)
  }

  // MARK: - Git Platform aliases

  private var aliases: [GitPlatformAlias] {
    settingsStore.settings.general.gitPlatformAliases
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
      Text("Git Platform aliases")
    } footer: {
      Text(
        "A Project uses the Git Platform of its origin remote. Add an alias when neither CLI "
          + "knows the host, for example an SSH host name that is not the API host. An alias "
          + "applies to every Project whose origin has that host, and it comes before the CLI hosts."
      )
      .font(.footnote)
      .foregroundStyle(.secondary)
    }
  }

  private func aliasRow(_ alias: GitPlatformAlias) -> some View {
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
        settingsStore.mutateGeneral { $0.removeGitPlatformAlias(id: alias.id) }
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
  nonisolated static func aliasStatus(_ alias: GitPlatformAlias, loggedInHosts: Set<String>?) -> AliasStatus {
    guard let loggedInHosts else { return .checking }
    if loggedInHosts.contains(alias.apiHost) { return .loggedIn(cliName: alias.kind.cliName) }
    return .notLoggedIn(message: GitPlatformError.notAuthenticated(alias.kind, host: alias.apiHost).userFacingMessage)
  }

  /// Saves the alias, or returns the message that says why it cannot be saved.
  private func saveAlias(_ alias: GitPlatformAlias) -> String? {
    var general = settingsStore.settings.general
    do {
      try general.saveGitPlatformAlias(alias)
    } catch {
      return error.message
    }
    settingsStore.mutateGeneral { $0.gitPlatformAliases = general.gitPlatformAliases }
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
  let alias: GitPlatformAlias?
}

/// Add / edit form for one Git Platform alias.
private struct GitPlatformAliasEditorSheet: View {
  let draft: AliasDraft
  let save: (GitPlatformAlias) -> String?
  let dismiss: () -> Void

  @State private var remoteHost = ""
  @State private var kind: GitPlatformKind = .gitlab
  @State private var apiHost = ""
  @State private var errorMessage: String?

  private var isEditing: Bool { draft.alias != nil }

  var body: some View {
    VStack(alignment: .leading, spacing: 14) {
      Text(isEditing ? "Edit Git Platform Alias" : "Add Git Platform Alias")
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
        Picker("Git Platform", selection: $kind) {
          ForEach(GitPlatformKind.allCases, id: \.self) { kind in
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
          let alias = GitPlatformAlias(
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

/// Install or `auth login` command of a CLI: the command in a monospaced, selectable code style,
/// with a trailing icon-only copy button. The icon changes to a checkmark for a short
/// time after a click, as in `GitEnvironmentBanner`.
struct CLIInstallCommandRow: View {
  let command: String
  var copyLabel = "Copy install command"

  @State private var didCopy = false

  var body: some View {
    HStack(spacing: 6) {
      Text(command)
        .font(.callout.monospaced())
        .textSelection(.enabled)
        .lineLimit(1)
        .padding(.horizontal, 6)
        .padding(.vertical, 3)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 4))
      Button {
        Self.copy(command)
        didCopy = true
        // Revert the checkmark so a second copy still reads as a fresh confirmation.
        Task {
          try? await Task.sleep(for: .seconds(2))
          didCopy = false
        }
      } label: {
        Image(systemName: didCopy ? "checkmark" : "doc.on.doc")
      }
      .buttonStyle(.borderless)
      .help(copyLabel)
      .accessibilityLabel(copyLabel)
    }
  }

  static func copy(_ command: String, to pasteboard: NSPasteboard = .general) {
    pasteboard.clearContents()
    pasteboard.setString(command, forType: .string)
  }
}

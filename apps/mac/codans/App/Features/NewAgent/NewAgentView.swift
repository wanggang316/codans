import CodansCore
import ComposableArchitecture
import SwiftUI

/// Sheet for `NewAgentFeature`, laid out like an issue composer: the
/// project and the place the agent works on top, the new worktree's branch
/// name and options as grouped rows below, and the prompt box with its agent
/// menu and send button at the bottom.
///
/// The worktree rows reuse the Create Worktree sheet's fields and copy so
/// the two dialogs read the same; only the layout differs.
struct NewAgentView: View {
  @Bindable var store: StoreOf<NewAgentFeature>
  @Environment(SettingsStore.self) private var settingsStore
  @Environment(AgentInstallationStore.self) private var installation
  @FocusState private var focus: Field?

  private enum Field: Hashable {
    case branchName
    case prompt
  }

  private static let width: CGFloat = 560
  /// About six lines of the prompt font.
  private static let editorHeight: CGFloat = 110

  var body: some View {
    let profiles = offeredProfiles
    VStack(spacing: 0) {
      header
        // Same 24 pt top inset and 16 pt rhythm as the Command Queue sheet;
        // the grouped form adds its own inset above the first section.
        .padding(.horizontal, 20)
        .padding(.top, 24)
        .padding(.bottom, 8)
      Form {
        if store.isCreatingWorktree, let form = store.scope(state: \.worktree, action: \.worktree) {
          worktreeSections(form)
        }
        composerSection
      }
      .formStyle(.grouped)
      .scrollBounceBehavior(.basedOnSize)
    }
    .frame(width: Self.width)
    .onAppear {
      store.send(.onAppear)
      focus = store.isCreatingWorktree ? .branchName : .prompt
    }
    // Settings edits and CLI installs change what the agent menu offers;
    // the profile list doubles as the task identity.
    .task(id: profiles) { store.send(.agentProfilesChanged(profiles)) }
    .onExitCommand { store.send(.cancelTapped) }
  }

  /// Enabled profiles whose CLI the shell can resolve — the same set the
  /// rest of the app offers.
  private var offeredProfiles: [AgentProfile] {
    AgentInstallationStore.offeredProfiles(
      enabled: settingsStore.settings.agents.enabledProfiles,
      isInstalled: installation.isInstalled
    )
  }

  // MARK: - Header

  /// Title, then the project and worktree selectors with the worktree
  /// options switch at the trailing edge.
  private var header: some View {
    VStack(alignment: .leading, spacing: 16) {
      Text("New Agent")
        .font(.headline)
      HStack(spacing: 14) {
        projectControl
        if store.selectedProject?.isGit == true, let form = store.worktree {
          targetMenu(loading: form.loadingOptions)
        }
        Spacer(minLength: 12)
        if store.isCreatingWorktree {
          Toggle(
            isOn: Binding(
              get: { store.showsWorktreeOptions },
              set: { _ in store.send(.worktreeOptionsToggled) }
            )
          ) {
            Image(systemName: "switch.2")
          }
          .toggleStyle(.button)
          .buttonStyle(.borderless)
          .help(store.showsWorktreeOptions ? "Hide Worktree Options" : "Show Worktree Options")
          .accessibilityLabel("Worktree Options")
        }
      }
    }
  }

  /// A selector drawn as its title and a chevron, with no bezel — the same
  /// borderless menu as the agent menu beside the send button. The inline
  /// picker gives the rows their checkmarks.
  private func selectorMenu<Content: View>(
    _ title: String, systemImage: String, accessibilityLabel: String,
    @ViewBuilder content: () -> Content
  ) -> some View {
    Menu {
      content()
    } label: {
      Label(title, systemImage: systemImage)
    }
    .menuStyle(.borderlessButton)
    .fixedSize()
    .accessibilityLabel(accessibilityLabel)
  }

  @ViewBuilder
  private var projectControl: some View {
    if store.projects.isEmpty {
      // Nothing to start an agent in yet: offer the sidebar's Add Project
      // menu in the project's place.
      selectorMenu("Add Project", systemImage: "plus", accessibilityLabel: "Add Project") {
        Button {
          store.send(.addProjectTapped(.openFolder))
        } label: {
          Label("Open Project…", systemImage: "folder")
        }
        Button {
          store.send(.addProjectTapped(.cloneRepository))
        } label: {
          Label("Clone Repository…", systemImage: "square.and.arrow.down.on.square")
        }
        Button {
          store.send(.addProjectTapped(.connectServer))
        } label: {
          Label("Connect to Server…", systemImage: "tv.badge.wifi")
        }
        Button {
          store.send(.addProjectTapped(.newWorkspace))
        } label: {
          Label("New Workspace…", systemImage: "square.stack.3d.up")
        }
      }
    } else {
      let selected = store.selectedProject
      selectorMenu(
        selected?.name ?? "Project",
        systemImage: selected?.symbol ?? ProjectIconView.folderSymbol,
        accessibilityLabel: "Project"
      ) {
        Picker(
          "Project",
          selection: Binding(
            get: { store.projectID },
            set: { if let id = $0 { store.send(.projectSelected(id)) } }
          )
        ) {
          ForEach(store.projects) { project in
            Label(project.name, systemImage: project.symbol)
              .tag(ProjectID?.some(project.id))
          }
        }
        .pickerStyle(.inline)
        .labelsHidden()
      }
    }
  }

  /// "New Worktree", then the project's local and remote branches.
  private func targetMenu(loading: Bool) -> some View {
    let title: String
    let symbol: String
    switch store.target {
    case .newWorktree:
      title = "New Worktree"
      symbol = "plus.square.on.square"
    case .branch(let ref):
      title = ref
      symbol = "point.3.connected.trianglepath.dotted"
    }
    return selectorMenu(title, systemImage: symbol, accessibilityLabel: "Worktree") {
      Picker(
        "Worktree",
        selection: Binding(
          get: { store.target },
          set: { store.send(.targetSelected($0)) }
        )
      ) {
        Label("New Worktree", systemImage: "plus.square.on.square")
          .tag(NewAgentFeature.Target.newWorktree)
        let locals = store.localBranches
        let remotes = store.remoteBranches
        if !locals.isEmpty {
          Section("Local Branches") {
            ForEach(locals, id: \.self) { branch in
              Text(branch).tag(NewAgentFeature.Target.branch(branch))
            }
          }
        }
        if !remotes.isEmpty {
          Section("Remote Branches") {
            ForEach(remotes, id: \.self) { ref in
              Text(ref).tag(NewAgentFeature.Target.branch(ref))
            }
          }
        }
      }
      .pickerStyle(.inline)
      .labelsHidden()
    }
    .disabled(loading)
  }

  // MARK: - Worktree

  @ViewBuilder
  private func worktreeSections(_ form: StoreOf<CreateWorktreeFeature>) -> some View {
    Section {
      TextField(
        "Branch name",
        text: Binding(
          get: { form.branchNameDraft },
          set: { form.send(.branchDraftChanged($0)) }
        ),
        prompt: Text("feature/login")
      )
      .focused($focus, equals: .branchName)
      .onSubmit { focus = .prompt }
    } footer: {
      if let note = Self.branchNote(form) {
        Text(note.text)
          .font(.caption)
          .foregroundStyle(note.isError ? .red : .orange)
          .fixedSize(horizontal: false, vertical: true)
          .frame(maxWidth: .infinity, alignment: .leading)
      }
    }

    if store.showsWorktreeOptions {
      Section {
        if form.loadingOptions {
          LabeledContent("Base ref") {
            ProgressView().controlSize(.small)
          }
        } else {
          Picker(
            "Base ref",
            selection: Binding(
              get: { form.selectedBaseRef ?? "" },
              set: { form.send(.baseRefSelected($0.isEmpty ? nil : $0)) }
            )
          ) {
            ForEach(form.baseRefOptions, id: \.self) { ref in
              Text(ref).tag(ref)
            }
          }
        }
        Toggle(
          "Fetch origin before creating worktree",
          isOn: Binding(
            get: { form.fetchOrigin },
            set: { form.send(.fetchOriginToggled($0)) }
          )
        )
        // Copying is a local streaming-create capability; a server project
        // runs plain `git worktree add` on the host.
        if !form.isRemote {
          Toggle(
            "Copy ignored files",
            isOn: Binding(
              get: { form.copyIgnored },
              set: { form.send(.copyIgnoredToggled($0)) }
            )
          )
          Toggle(
            "Copy untracked files",
            isOn: Binding(
              get: { form.copyUntracked },
              set: { form.send(.copyUntrackedToggled($0)) }
            )
          )
        }
      }
    }
  }

  /// The form's validation, collision, cap, or submit message — at most one,
  /// most specific first. Collisions are warnings: the user can pick another
  /// name, so they read orange like the Create Worktree sheet's note.
  private static func branchNote(_ form: StoreOf<CreateWorktreeFeature>) -> (text: String, isError: Bool)? {
    if let error = form.validationError { return (error, true) }
    if form.branchCollisionKind != .none {
      return (CreateWorktreeSheet.collisionNote(for: form.state), false)
    }
    if form.currentPendingCountForProject >= 8 { return (CreateWorktreeFeature.capMessage, false) }
    if let error = form.submitError { return (error, true) }
    return nil
  }

  // MARK: - Composer

  private var composerSection: some View {
    Section {
      VStack(alignment: .leading, spacing: 4) {
        editor
        HStack(spacing: 8) {
          Spacer()
          agentMenu
          sendButton
        }
      }
    } footer: {
      if let error = store.submitError {
        Text(error)
          .font(.caption)
          .foregroundStyle(.red)
          .fixedSize(horizontal: false, vertical: true)
          .frame(maxWidth: .infinity, alignment: .leading)
      }
    }
  }

  private var editor: some View {
    TextEditor(text: $store.prompt.sending(\.promptChanged))
      .font(.body)
      .scrollContentBackground(.hidden)
      .focusEffectDisabled()
      .frame(height: Self.editorHeight)
      .overlay(alignment: .topLeading) {
        if store.prompt.isEmpty {
          // `TextEditor` has no placeholder of its own; this sits where the
          // first line of text will, matching the text container's inset.
          Text("What should the agent do? (⇧↩ for a new line)")
            .foregroundStyle(.tertiary)
            .padding(.leading, 5)
            .allowsHitTesting(false)
        }
      }
      .focused($focus, equals: .prompt)
      .onKeyPress(.return, phases: .down) { press in
        // Return sends; ⇧Return and ⌥Return break a line, as in the
        // Command Queue composer.
        if press.modifiers.contains(.shift) || press.modifiers.contains(.option) {
          return .ignored
        }
        if store.canSend { store.send(.sendTapped) }
        return .handled
      }
      .onKeyPress(.escape) {
        // `NSTextView` would spend Escape on word completion.
        store.send(.cancelTapped)
        return .handled
      }
      .accessibilityLabel("Prompt")
  }

  /// The agent to send to, as the small borderless menu a chat composer
  /// keeps beside its send button. The inline picker gives the rows their
  /// checkmarks; Manage Agents… sits under them.
  private var agentMenu: some View {
    Menu {
      if !store.agentProfiles.isEmpty {
        Picker(
          "Agent",
          selection: Binding(
            get: { store.agentProfileID },
            set: { if let id = $0 { store.send(.agentSelected(id)) } }
          )
        ) {
          ForEach(store.agentProfiles) { profile in
            Label {
              Text(profile.displayName)
            } icon: {
              AgentMenuIcon.image(for: profile.icon)
                .accessibilityHidden(true)
            }
            .tag(UUID?.some(profile.id))
          }
        }
        .pickerStyle(.inline)
        .labelsHidden()
        Divider()
      }
      Button("Manage Agents…") { store.send(.manageAgentsTapped) }
    } label: {
      if let agent = store.selectedAgent {
        Label {
          Text(agent.displayName)
        } icon: {
          AgentMenuIcon.image(for: agent.icon)
        }
        .font(.callout)
        .foregroundStyle(.secondary)
      } else {
        Text("No Agent")
          .font(.callout)
          .foregroundStyle(.secondary)
      }
    }
    .menuStyle(.borderlessButton)
    .fixedSize()
    .help("Agent")
    .accessibilityLabel("Agent")
  }

  private var sendButton: some View {
    Button {
      store.send(.sendTapped)
    } label: {
      Image(systemName: "arrow.up.circle.fill")
        .font(.system(size: 26))
        .symbolRenderingMode(.hierarchical)
        .foregroundStyle(store.canSend ? Color.accentColor : Color.secondary)
    }
    .buttonStyle(.plain)
    // ⌘↩ as well as the prompt's plain Return, so sending works from the
    // branch-name field too.
    .keyboardShortcut(.return, modifiers: .command)
    .disabled(!store.canSend)
    .help(sendHelp)
    .accessibilityLabel("Send")
  }

  private var sendHelp: String {
    if store.selectedProject == nil { return "Add a project first" }
    if store.selectedAgent == nil { return "Choose an agent in Settings → Agents" }
    if store.isCreatingWorktree,
      store.worktree?.branchNameDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true
    {
      return "Name the new worktree's branch"
    }
    return "Send (⌘↩)"
  }
}

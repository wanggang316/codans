import CodansCore
import ComposableArchitecture
import SwiftUI

/// Sheet for `NewAgentFeature`, laid out like an issue composer: the
/// project and the place the agent works on top, the new worktree's branch
/// name and options as grouped rows below, and the prompt box with its agent
/// menu and send button at the bottom.
///
/// The worktree rows are the New Worktree sheet's shared rows and branch
/// note, so the two dialogs read the same; only the layout differs.
struct NewAgentView: View {
  @Bindable var store: StoreOf<NewAgentFeature>
  @Environment(SettingsStore.self) private var settingsStore
  @Environment(AgentInstallationStore.self) private var installation
  @FocusState private var focus: Field?
  @State private var showsFilePicker = false
  @State private var promptSelection = ComposerSelection()

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
      Text("New Agent")
        .font(.headline)
        .frame(maxWidth: .infinity, alignment: .leading)
        // Same 24 pt top inset as the Command Queue sheet.
        .padding(.horizontal, 20)
        .padding(.top, 24)
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
    .composerFilePicker(isPresented: $showsFilePicker) { urls in
      promptSelection.insertPaths(urls, into: store.prompt) { store.send(.filesSelected(urls, selection: $0)) }
      focus = .prompt
    }
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

  /// The project and worktree selectors, with the worktree options switch
  /// at the trailing edge. It is the first section's header, so it sits
  /// close to the rows it drives and the form's top inset separates it from
  /// the title. The grouped form ignores `contentMargins`, so that inset
  /// cannot be tuned from outside.
  private var selectorRow: some View {
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
    // A section header is inset to the row text; the selectors line up
    // with the title and the card edges instead.
    .padding(.horizontal, -10)
  }

  /// A selector drawn as its title and a chevron, with no bezel — the same
  /// borderless menu as the agent menu beside the send button. The inline
  /// picker gives the rows their checkmarks.
  ///
  /// The accessibility label goes on the menu's label content, not on the
  /// `Menu`: AppKit takes the menu button's AX title from the label content
  /// on every update, so a label on the `Menu` gives way to the visible
  /// title (and the symbol's description) after a selection. The selection
  /// is the value, on the `Menu`.
  private func selectorMenu<Content: View>(
    _ title: String, systemImage: String, accessibilityLabel: String, accessibilityValue: String? = nil,
    @ViewBuilder content: () -> Content
  ) -> some View {
    Menu {
      content()
    } label: {
      Label(title, systemImage: systemImage)
        .accessibilityLabel(accessibilityLabel)
    }
    .menuStyle(.borderlessButton)
    .fixedSize()
    .accessibilityValue(accessibilityValue ?? "")
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
          store.send(.addProjectTapped(.openRemoteProject))
        } label: {
          Label("Open Remote Project…", systemImage: RemoteProjectMarker.symbol)
        }
        Button {
          store.send(.addProjectTapped(.newWorkspace))
        } label: {
          Label("New Workspace…", systemImage: "square.stack.3d.up")
        }
      }
    } else {
      let selected = store.selectedProject
      Menu {
        projectPicker
      } label: {
        Label {
          Text(selected?.name ?? "Project")
        } icon: {
          Image(nsImage: ProjectMenuRowLabel.icon(selected))
            .accessibilityHidden(true)
        }
        // On the label content, not the `Menu`: see `selectorMenu`.
        .accessibilityLabel("Project")
      }
      .menuStyle(.borderlessButton)
      .fixedSize()
      .accessibilityValue(selected?.name ?? "")
    }
  }

  /// Recent, then the project groups. A project in Recent is in its group
  /// too; both rows carry its tag, so both select it and both show checked.
  private var projectPicker: some View {
    Picker(
      "Project",
      selection: Binding(
        get: { store.projectID },
        set: { if let id = $0 { store.send(.projectSelected(id)) } }
      )
    ) {
      ProjectMenuContent(menu: store.projectMenu) { project, marksRemote in
        ProjectMenuRowLabel(project: project, marksRemote: marksRemote)
          .tag(ProjectID?.some(project.id))
      }
    }
    .pickerStyle(.inline)
    .labelsHidden()
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
    return selectorMenu(title, systemImage: symbol, accessibilityLabel: "Worktree", accessibilityValue: title) {
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
    } header: {
      selectorRow
    } footer: {
      WorktreeBranchNoteFooter(note: form.branchNote)
    }

    if store.showsWorktreeOptions {
      Section {
        WorktreeOptionRows(form: form)
      }
    }
  }

  // MARK: - Composer

  private var composerSection: some View {
    Section {
      VStack(alignment: .leading, spacing: 4) {
        editor
        HStack(spacing: 8) {
          ComposerFilePickerButton { showsFilePicker = true }
          Spacer()
          agentMenu
          sendButton
        }
      }
    } header: {
      // Without the worktree rows, the composer is the first section.
      if !store.isCreatingWorktree {
        selectorRow
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
    ComposerTextEditor(text: $store.prompt.sending(\.promptChanged), selection: promptSelection)
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
      Group {
        if let agent = store.selectedAgent {
          Label {
            Text(agent.displayName)
          } icon: {
            AgentMenuIcon.image(for: agent.icon)
          }
        } else {
          Text("No Agent")
        }
      }
      .font(.callout)
      .foregroundStyle(.secondary)
      // On the label content, not the `Menu`: see `selectorMenu`.
      .accessibilityLabel("Agent")
    }
    .menuStyle(.borderlessButton)
    .fixedSize()
    .help("Agent")
    .accessibilityValue(store.selectedAgent?.displayName ?? "")
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
    return ShortcutDisplay.tooltip("Send", chord: "⌘↩")
  }
}

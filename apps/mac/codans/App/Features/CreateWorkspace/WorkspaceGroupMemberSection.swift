import CodansCore
import ComposableArchitecture
import SwiftUI

/// One project of a new group, as a form section: the checkout it gets on
/// the group branch, then the same options the Create Worktree sheet offers
/// (base ref, fetch, copy ignored / untracked files, agent), seeded from
/// the project's settings. The footer shows the project's findings, or its
/// progress once creation runs.
struct WorkspaceGroupMemberSection: View {
  let store: StoreOf<CreateWorkspaceFeature>
  let member: GroupMemberDraft

  var body: some View {
    Section {
      WorkspaceRefPicker(
        title: "Based on",
        refs: member.refs,
        selection: member.options.baseRef,
        placeholder: "Default (\(member.refs.inventory?.defaultBase ?? "HEAD"))",
        includeLocal: true,
        includeRemote: true,
        onSelect: { send(.baseRefChanged($0)) })
      Toggle("Fetch remote before checkout", isOn: binding(\.fetch, { .fetchChanged($0) }))
      Toggle("Copy ignored files", isOn: binding(\.copyIgnored, { .copyIgnoredChanged($0) }))
      Toggle("Copy untracked files", isOn: binding(\.copyUntracked, { .copyUntrackedChanged($0) }))
      if !store.agentProfiles.isEmpty {
        agentPicker
      }
      if let command = member.options.setupCommand {
        LabeledContent("Setup script") {
          Text(command)
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .truncationMode(.tail)
            .help(command)
        }
      }
    } header: {
      HStack(alignment: .firstTextBaseline, spacing: 6) {
        Text(member.name)
        WorkspaceCheckoutLine(checkout: checkout)
      }
      Text((member.options.sourceGitRoot as NSString).abbreviatingWithTildeInPath)
        .lineLimit(1)
        .truncationMode(.middle)
    } footer: {
      status
    }
  }

  private var checkout: WorkspaceCheckoutDescription {
    let branch = store.groupBranch
    let base = member.options.baseRef ?? member.refs.inventory?.defaultBase ?? "the default branch"
    return .newBranch(branch: branch.isEmpty ? nil : branch, base: base)
  }

  /// Launched once every checkout of the group exists and the setup
  /// scripts have run.
  private var agentPicker: some View {
    Picker("Launch agent", selection: binding(\.agentProfileID, { .agentChanged($0) })) {
      Text("None").tag(UUID?.none)
      Divider()
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
  }

  // MARK: Status

  @ViewBuilder
  private var status: some View {
    switch member.progress {
    case .pending where store.creation.isBusy:
      caption("Waiting\u{2026}")
    case .pending:
      VStack(alignment: .leading, spacing: 2) {
        refsStatus
        IssueList(issues: store.state.issues(for: member).filter { !isRefsFailure($0) })
      }
    case .running(let phase, let lastLine):
      progress([phaseTitle(phase), lastLine].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " "))
    case .settingUp(let lastLine):
      progress(["Running the setup script\u{2026}", lastLine].compactMap { $0 }.joined(separator: " "))
    case .done:
      Label("Checked out.", systemImage: "checkmark.circle.fill")
        .foregroundStyle(.secondary)
    case .failed(let message):
      Text(message)
        .foregroundStyle(.red)
        .textSelection(.enabled)
        .fixedSize(horizontal: false, vertical: true)
    case .rolledBack:
      caption("Rolled back.")
    case .setupFailed(let reason):
      Text("Checked out, but the setup script failed: \(reason)")
        .foregroundStyle(.orange)
        .textSelection(.enabled)
        .fixedSize(horizontal: false, vertical: true)
    }
  }

  @ViewBuilder
  private var refsStatus: some View {
    switch member.refs {
    case .idle, .loaded:
      EmptyView()
    case .loading:
      HStack(spacing: 6) {
        ProgressView().controlSize(.mini)
        Text("Loading branches\u{2026}").foregroundStyle(.secondary)
      }
    case .failed(let message):
      HStack(spacing: 6) {
        Text(message)
          .foregroundStyle(.orange)
          .fixedSize(horizontal: false, vertical: true)
        Button("Retry") { send(.retryRefsTapped) }
          .buttonStyle(.link)
      }
    }
  }

  private func isRefsFailure(_ issue: MemberIssue) -> Bool {
    if case .failed(let message) = member.refs { return issue.message == message }
    return false
  }

  private func caption(_ text: String) -> some View {
    Text(text)
      .foregroundStyle(.secondary)
      .lineLimit(1)
      .truncationMode(.middle)
  }

  private func progress(_ text: String) -> some View {
    HStack(spacing: 6) {
      ProgressView().controlSize(.mini)
      caption(text)
    }
  }

  private func phaseTitle(_ phase: WorkspaceCreationEvent.Phase) -> String {
    switch phase {
    case .cloning: return "Cloning\u{2026}"
    case .fetching: return "Fetching\u{2026}"
    case .checkingOut: return "Checking out\u{2026}"
    }
  }

  // MARK: Plumbing

  private func send(_ action: CreateWorkspaceFeature.Action.GroupMemberAction) {
    store.send(.groupMember(member.id, action))
  }

  private func binding<Value>(
    _ keyPath: KeyPath<MemberCreationOptions, Value>,
    _ action: @escaping (Value) -> CreateWorkspaceFeature.Action.GroupMemberAction
  ) -> Binding<Value> {
    // Read through the store so the control follows the draft as it changes.
    let id = member.id
    let fallback = member.options[keyPath: keyPath]
    return Binding(
      get: { store.groupMembers[id: id]?.options[keyPath: keyPath] ?? fallback },
      set: { store.send(.groupMember(id, action($0))) })
  }
}

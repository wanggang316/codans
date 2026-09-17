import CodansCore
import ComposableArchitecture
import SwiftUI

/// One repository of the New Workspace form: how it is checked out, the
/// branch fields that mode needs, where a remote is cloned, and the folder
/// it gets. The footer carries its problems, or its progress while the
/// workspace is being created.
struct WorkspaceMemberSection: View {
  let store: StoreOf<CreateWorkspaceFeature>
  let member: MemberDraft

  var body: some View {
    Section {
      Picker("Checkout", selection: binding(\.mode, { .modeChanged($0) })) {
        ForEach(member.availableModes, id: \.self) { mode in
          Text(mode.title).tag(mode)
        }
      }
      switch member.mode {
      case .newBranch:
        newBranchRows
      case .existingLocal:
        WorkspaceRefPicker(
          title: "Branch",
          refs: member.refs,
          selection: member.localBranch,
          placeholder: "Choose a branch",
          includeLocal: true,
          includeRemote: false,
          onSelect: { send(.localBranchChanged($0)) })
      case .existingRemote:
        remoteBranchRows
      }
      if case .remote(_, let destination) = member.source {
        cloneDestinationRow(destination)
      }
      TextField("Folder name", text: binding(\.name, { .nameChanged($0) }))
    } header: {
      header
    } footer: {
      footer
    }
  }

  // MARK: Rows

  @ViewBuilder
  private var newBranchRows: some View {
    let shared = store.sharedBranch.trimmingCharacters(in: .whitespacesAndNewlines)
    LabeledContent {
      TextField(
        "Branch",
        text: binding(\.branchOverride, { .branchOverrideChanged($0) }),
        prompt: Text(shared.isEmpty ? "branch-name" : shared)
      )
      .labelsHidden()
    } label: {
      Text("Branch")
      if !store.isAddMode {
        Text("Empty uses the workspace branch.")
      }
    }
    WorkspaceRefPicker(
      title: "Based on",
      refs: member.refs,
      selection: member.baseRef,
      placeholder: defaultBaseTitle,
      includeLocal: true,
      includeRemote: true,
      onSelect: { send(.baseRefChanged($0)) })
  }

  private var defaultBaseTitle: String {
    member.refs.inventory?.defaultBaseRef.map { "Default (\($0))" } ?? "Default branch"
  }

  @ViewBuilder
  private var remoteBranchRows: some View {
    WorkspaceRefPicker(
      title: "Remote branch",
      refs: member.refs,
      selection: member.remoteRef,
      placeholder: "Choose a remote branch",
      includeLocal: false,
      includeRemote: true,
      onSelect: { send(.remoteRefChanged($0)) })
    if member.hasLocalConflict, let branch = member.remoteRefBranch {
      Picker(selection: binding(\.localConflict, { .localConflictChanged($0) })) {
        Text("Keep local branch").tag(MemberDraft.LocalConflictResolution.keepLocal)
        Text("Reset to \(member.remoteRef ?? "remote")").tag(MemberDraft.LocalConflictResolution.resetToRemote)
      } label: {
        Text("Local branch")
        Text("A local branch named \u{201C}\(branch)\u{201D} already exists.")
      }
    }
  }

  private func cloneDestinationRow(_ destination: String) -> some View {
    LabeledContent {
      HStack(spacing: 6) {
        PathText(path: destination)
        Button {
          send(.chooseCloneDestinationTapped)
        } label: {
          Image(systemName: "folder")
            .accessibilityLabel("Choose Clone Location")
        }
        .buttonStyle(.borderless)
        .help("Choose the folder to clone into")
      }
    } label: {
      Text("Clone to")
      Text("Reused if already cloned there.")
    }
  }

  // MARK: Header / footer

  private var header: some View {
    HStack(alignment: .firstTextBaseline, spacing: 8) {
      VStack(alignment: .leading, spacing: 1) {
        Text(member.source.title)
        Text(member.source.location)
          .font(.caption)
          .fontWeight(.regular)
          .foregroundStyle(.secondary)
          .lineLimit(1)
          .truncationMode(.middle)
          .help(member.source.location)
      }
      Spacer()
      Button("Remove") {
        send(.remove)
      }
      .buttonStyle(.borderless)
      .fontWeight(.regular)
      .disabled(store.creation.isBusy)
    }
  }

  @ViewBuilder
  private var footer: some View {
    switch member.progress {
    case .pending where store.creation.isBusy:
      Text("Waiting…").foregroundStyle(.secondary)
    case .pending:
      VStack(alignment: .leading, spacing: 2) {
        refsStatus
        IssueList(issues: listedIssues)
      }
    case .running(let phase, let lastLine):
      HStack(spacing: 6) {
        ProgressView().controlSize(.mini)
        Text(phaseTitle(phase))
        if let lastLine, !lastLine.isEmpty {
          Text(lastLine)
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .truncationMode(.middle)
        }
      }
    case .done:
      Label("Checked out", systemImage: "checkmark.circle.fill")
        .foregroundStyle(.secondary)
    case .failed(let message):
      Text(message)
        .foregroundStyle(.red)
        .textSelection(.enabled)
        .fixedSize(horizontal: false, vertical: true)
    case .rolledBack:
      Text("Rolled back.").foregroundStyle(.secondary)
    }
  }

  /// Everything but a refs failure, which `refsStatus` shows with Retry.
  private var listedIssues: [MemberIssue] {
    let issues = store.state.issues(for: member)
    guard case .failed(let message) = member.refs else { return issues }
    return issues.filter { $0.message != message }
  }

  @ViewBuilder
  private var refsStatus: some View {
    switch member.refs {
    case .idle, .loaded:
      EmptyView()
    case .loading:
      HStack(spacing: 6) {
        ProgressView().controlSize(.mini)
        Text("Loading branches…").foregroundStyle(.secondary)
      }
    case .failed(let message):
      HStack(spacing: 6) {
        Text(message)
          .foregroundStyle(member.mode == .existingRemote ? .red : .orange)
          .fixedSize(horizontal: false, vertical: true)
        Button("Retry") { send(.retryRefsTapped) }
          .buttonStyle(.link)
      }
    }
  }

  private func phaseTitle(_ phase: WorkspaceCreationEvent.Phase) -> String {
    switch phase {
    case .cloning: return "Cloning…"
    case .fetching: return "Fetching…"
    case .checkingOut: return "Checking out…"
    }
  }

  // MARK: Plumbing

  private func send(_ action: CreateWorkspaceFeature.Action.MemberAction) {
    store.send(.member(member.id, action))
  }

  private func binding<Value>(
    _ keyPath: KeyPath<MemberDraft, Value>,
    _ action: @escaping (Value) -> CreateWorkspaceFeature.Action.MemberAction
  ) -> Binding<Value> {
    Binding(get: { member[keyPath: keyPath] }, set: { send(action($0)) })
  }
}

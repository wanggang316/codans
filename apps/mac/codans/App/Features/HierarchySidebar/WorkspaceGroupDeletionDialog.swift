import CodansCore
import ComposableArchitecture
import SwiftUI

/// Sheet for `WorkspaceGroupDeletionFeature`, laid out as a grouped form
/// like the other Workspace sheets: the projects the delete covers with
/// their risks, the running terminals and other files it would remove, the
/// branch choice with the branches it would delete, and the acknowledgment.
/// Cancel / Delete sit in the bottom bar with the check status.
struct WorkspaceGroupDeletionDialog: View {
  @Bindable var store: StoreOf<WorkspaceGroupDeletionFeature>

  var body: some View {
    VStack(spacing: 0) {
      Form {
        headerSection
        ForEach(store.checks, id: \.groupID) { check in
          groupSection(check)
        }
        if !store.runningTerminals.isEmpty {
          Section("Running Terminals") {
            ForEach(store.runningTerminals, id: \.self) { name in
              Label(name, systemImage: "terminal")
            }
          }
        }
        if !store.previousFailures.isEmpty {
          Section {
            ForEach(store.previousFailures, id: \.path) { failure in
              DeletionFailureRow(title: failure.name, path: failure.path, reason: failure.reason)
            }
          } header: {
            Text("Not Removed Last Time")
          }
        }
        if store.phase != .checking, !store.isBlocked {
          branchesSection
          if store.hasRisks {
            acknowledgmentSection
          }
        }
      }
      .formStyle(.grouped)
      .scrollBounceBehavior(.basedOnSize)
      .disabled(store.phase == .deleting)
      bar
    }
    .frame(width: 520)
    .frame(minHeight: 280, maxHeight: 680)
  }

  // MARK: Sections

  @ViewBuilder
  private var headerSection: some View {
    Section {
      EmptyView()
    } header: {
      switch store.target {
      case .group(_, _, let name):
        Text("Delete Group “\(name)”?")
        Text(
          "Removes each checkout of the group and the group folder. Source projects and other groups do not change."
        )
      case .workspace(_, let name):
        Text("Delete Files of “\(name)”?")
        Text(
          "Deletes every group with its checkouts, the default links, and the workspace folder, then removes the workspace from the sidebar. Source projects do not change."
        )
      }
    }
    .headerProminence(.increased)
  }

  @ViewBuilder
  private func groupSection(_ check: GroupDeletionCheck) -> some View {
    Section {
      if check.members.isEmpty && check.groupCheckFailures.isEmpty {
        Text("No checkouts.")
          .foregroundStyle(.secondary)
      }
      ForEach(check.members, id: \.path) { member in
        MemberRow(member: member)
      }
      ForEach(check.groupCheckFailures, id: \.self) { failure in
        Label(failure, systemImage: "exclamationmark.triangle.fill")
          .foregroundStyle(.red)
          .textSelection(.enabled)
      }
      if !check.extraEntries.isEmpty {
        LabeledContent("Other files in the group folder") {
          Text(check.extraEntries.joined(separator: ", "))
            .foregroundStyle(.orange)
            .lineLimit(3)
            .truncationMode(.middle)
            .help(check.extraEntries.joined(separator: "\n"))
        }
      }
    } header: {
      if case .workspace = store.target {
        Text(check.groupName)
      } else {
        Text("Projects")
      }
    }
  }

  @ViewBuilder
  private var branchesSection: some View {
    let branches = store.deletableBranches
    Section {
      Toggle(
        "Also delete branches",
        isOn: Binding(get: { store.deleteBranches }, set: { store.send(.deleteBranchesChanged($0)) })
      )
      .disabled(branches.isEmpty)
    } footer: {
      Text(
        branches.isEmpty
          ? "No branch can be deleted: each one existed before the group, is checked out elsewhere, or is a default branch."
          : "Deletes \(branches.joined(separator: ", ")). Other branches stay."
      )
      .foregroundStyle(.secondary)
    }
  }

  private var acknowledgmentSection: some View {
    Section {
      Toggle(
        "Discard these changes and stop the terminals",
        isOn: Binding(get: { store.acknowledgesRisks }, set: { store.send(.acknowledgesRisksChanged($0)) })
      )
      .toggleStyle(.checkbox)
    } footer: {
      Text("Uncommitted changes, unpushed commits, and other files listed above are lost.")
        .foregroundStyle(.secondary)
    }
  }

  // MARK: Bar

  private var bar: some View {
    HStack(spacing: 8) {
      status
      Spacer(minLength: 12)
      Button("Cancel", role: .cancel) {
        store.send(.cancelTapped)
      }
      .keyboardShortcut(.cancelAction)
      .disabled(store.phase == .deleting)
      Button("Delete", role: .destructive) {
        store.send(.deleteTapped)
      }
      .disabled(!store.canDelete)
    }
    .padding(.horizontal, 20)
    .padding(.top, 4)
    .padding(.bottom, 20)
  }

  @ViewBuilder
  private var status: some View {
    switch store.phase {
    case .checking:
      progress("Checking for changes…")
    case .deleting:
      progress("Deleting…")
    case .ready:
      if store.isBlocked {
        HStack(spacing: 8) {
          Text("A check failed. Nothing can be deleted until it passes.")
            .foregroundStyle(.red)
            .lineLimit(2)
          Button("Retry") {
            store.send(.checkRequested)
          }
        }
      } else if let message = store.errorMessage {
        Text(message)
          .foregroundStyle(.red)
          .lineLimit(2)
          .textSelection(.enabled)
          .help(message)
      }
    }
  }

  private func progress(_ text: String) -> some View {
    HStack(spacing: 8) {
      ProgressView().controlSize(.small)
      Text(text)
        .foregroundStyle(.secondary)
        .lineLimit(1)
    }
  }
}

/// One member checkout: name and branch, the path beneath, and what the
/// delete would lose (or why it could not be checked) on the trailing side.
private struct MemberRow: View {
  let member: GroupDeletionCheck.Member

  var body: some View {
    LabeledContent {
      VStack(alignment: .trailing, spacing: 2) {
        if let failure = member.checkFailure {
          Text(failure)
            .foregroundStyle(.red)
            .lineLimit(2)
            .help(failure)
        } else if risks.isEmpty {
          Text("No changes")
            .foregroundStyle(.secondary)
        } else {
          ForEach(risks, id: \.self) { risk in
            Text(risk).foregroundStyle(.orange)
          }
        }
      }
    } label: {
      VStack(alignment: .leading, spacing: 2) {
        Text(member.branch.map { "\(member.name) · \($0)" } ?? member.name)
          .lineLimit(1)
        Text((member.path as NSString).abbreviatingWithTildeInPath)
          .font(.subheadline)
          .foregroundStyle(.secondary)
          .lineLimit(1)
          .truncationMode(.middle)
          .help(member.path)
      }
    }
  }

  private var risks: [String] {
    var risks: [String] = []
    if member.uncommittedCount > 0 {
      risks.append(
        member.uncommittedCount == 1 ? "1 uncommitted change" : "\(member.uncommittedCount) uncommitted changes")
    }
    if member.unpushedCount > 0 {
      risks.append(member.unpushedCount == 1 ? "1 unpushed commit" : "\(member.unpushedCount) unpushed commits")
    }
    return risks
  }
}

/// An item a delete could not remove, with the reason.
private struct DeletionFailureRow: View {
  let title: String
  let path: String
  let reason: String

  var body: some View {
    VStack(alignment: .leading, spacing: 2) {
      Text(title)
        .lineLimit(1)
      Text(reason)
        .font(.subheadline)
        .foregroundStyle(.red)
        .lineLimit(3)
        .textSelection(.enabled)
        .help("\(path)\n\(reason)")
    }
  }
}

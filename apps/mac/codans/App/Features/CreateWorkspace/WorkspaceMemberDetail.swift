import ComposableArchitecture
import Foundation
import SwiftUI

/// The expanded form for one member: folder name, checkout mode, branch and
/// ref pickers, the Keep / Reset choice when a remote branch meets a local
/// one, and for a remote source where to clone. Every issue is shown under
/// the field it concerns.
struct WorkspaceMemberDetail: View {
  let member: MemberDraft
  let issues: [MemberIssue]
  let sharedBranch: String
  let isDisabled: Bool
  let send: (CreateWorkspaceFeature.Action.MemberAction) -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      HStack(alignment: .top, spacing: 12) {
        field("Folder name") {
          TextField("name", text: Binding(get: { member.name }, set: { send(.nameChanged($0)) }))
            .textFieldStyle(.roundedBorder)
          issueCaptions(for: .name)
        }
        field("Checkout") {
          Picker("Checkout", selection: Binding(get: { member.mode }, set: { send(.modeChanged($0)) })) {
            ForEach(MemberDraft.CheckoutMode.allCases, id: \.self) { mode in
              Text(mode.title).tag(mode)
            }
          }
          .pickerStyle(.segmented)
          .labelsHidden()
        }
      }

      switch member.mode {
      case .newBranch:
        HStack(alignment: .top, spacing: 12) {
          branchField
          field("From") {
            RefPickerButton(
              selection: member.baseRef,
              options: member.refs.inventory?.options(includeLocal: true, includeRemote: true) ?? [],
              isLoading: member.refs.isLoading,
              allowsDefault: true,
              defaultBaseRef: member.refs.inventory?.defaultBaseRef,
              onSelect: { send(.baseRefChanged($0)) })
            issueCaptions(for: .baseRef)
          }
        }
      case .existingLocal:
        field("Branch") {
          RefPickerButton(
            selection: member.branch.isEmpty ? nil : member.branch,
            options: member.refs.inventory?.options(includeLocal: true, includeRemote: false) ?? [],
            isLoading: member.refs.isLoading,
            placeholder: "Choose a local branch",
            onSelect: { send(.branchChanged($0 ?? "")) })
          issueCaptions(for: .branch)
        }
      case .existingRemote:
        HStack(alignment: .top, spacing: 12) {
          field("Remote branch") {
            RefPickerButton(
              selection: member.remoteRef,
              options: member.refs.inventory?.options(includeLocal: false, includeRemote: true) ?? [],
              isLoading: member.refs.isLoading,
              placeholder: "Choose a remote branch",
              onSelect: { send(.remoteRefChanged($0)) })
            issueCaptions(for: .remoteRef)
          }
          branchField
        }
        if member.hasLocalConflict {
          Picker(
            "Local branch",
            selection: Binding(get: { member.localConflict }, set: { send(.localConflictChanged($0)) })
          ) {
            Text("Keep local").tag(MemberDraft.LocalConflictResolution.keepLocal)
            Text("Reset to \(member.remoteRef ?? "remote")").tag(MemberDraft.LocalConflictResolution.resetToRemote)
          }
          .pickerStyle(.radioGroup)
          .horizontalRadioGroupLayout()
          .labelsHidden()
        }
      }

      if case .remote(_, let destination, _) = member.source {
        field("Clone into") {
          HStack(spacing: 8) {
            TextField(
              "~/.codans/sources/\(member.name)",
              text: Binding(get: { destination }, set: { send(.cloneDestinationChanged($0)) })
            )
            .textFieldStyle(.roundedBorder)
            .font(.callout.monospaced())
            Button("Choose…") { send(.browseCloneDestinationTapped) }
          }
          issueCaptions(for: .cloneDestination)
        }
      }

      refsLine
      issueCaptions(for: .row)
    }
    .padding(.horizontal, 12)
    .padding(.vertical, 10)
    .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 6))
    .disabled(isDisabled)
  }

  private var branchField: some View {
    field(member.mode == .existingRemote ? "As local branch" : "Branch") {
      HStack(spacing: 6) {
        TextField("branch", text: Binding(get: { member.branch }, set: { send(.branchChanged($0)) }))
          .textFieldStyle(.roundedBorder)
          .font(.callout.monospaced())
        if showsUseShared {
          Button("Use shared") { send(.useSharedBranchTapped) }
            .buttonStyle(.link)
            .font(.caption)
        }
      }
      issueCaptions(for: .branch)
    }
  }

  private var showsUseShared: Bool {
    member.mode == .newBranch && (member.branchEditedManually || member.baseRefEditedManually)
      && !sharedBranch.isEmpty
  }

  @ViewBuilder
  private var refsLine: some View {
    switch member.refs {
    case .idle, .loaded:
      EmptyView()
    case .loading:
      HStack(spacing: 6) {
        ProgressView().controlSize(.mini)
        Text("Loading branches…").font(.caption).foregroundStyle(.secondary)
      }
    case .failed:
      HStack(spacing: 8) {
        issueCaptions(for: .refs)
        Button("Retry") { send(.loadRefsTapped) }
          .buttonStyle(.link)
          .font(.caption)
      }
    }
  }

  private func field<Content: View>(_ label: String, @ViewBuilder content: () -> Content) -> some View {
    VStack(alignment: .leading, spacing: 4) {
      Text(label).font(.caption).foregroundStyle(.secondary)
      content()
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }

  @ViewBuilder
  private func issueCaptions(for field: MemberIssue.Field) -> some View {
    ForEach(Array(issues.filter { $0.field == field }.enumerated()), id: \.offset) { _, issue in
      Text(issue.message)
        .font(.caption)
        .foregroundStyle(color(for: issue.severity))
        .textSelection(.enabled)
        .fixedSize(horizontal: false, vertical: true)
    }
  }

  private func color(for severity: MemberIssue.Severity) -> Color {
    switch severity {
    case .blocking: return .red
    case .warning: return .orange
    case .info: return .secondary
    }
  }
}

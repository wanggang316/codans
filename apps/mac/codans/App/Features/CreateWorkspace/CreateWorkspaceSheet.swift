import CodansCore
import ComposableArchitecture
import SwiftUI

/// Sheet for `CreateWorkspaceFeature`: title and folder, one field to add
/// members, the member rows with their expandable detail, the shared branch,
/// a preview of the result, and the footer. In add mode the workspace
/// fields are fixed and the same list adds one repository to an existing
/// workspace.
struct CreateWorkspaceSheet: View {
  @Bindable var store: StoreOf<CreateWorkspaceFeature>

  var body: some View {
    VStack(alignment: .leading, spacing: 14) {
      header
      if !store.isAddMode {
        workspaceFields
      }
      WorkspaceAddField(store: store)
      memberList
      if !store.isAddMode || !store.members.isEmpty {
        sharedBranchRow
      }
      Divider()
      WorkspacePreviewPanel(
        plan: store.draftPlan,
        showCommands: store.showCommands,
        onShowCommandsChanged: { store.send(.showCommandsChanged($0)) })
      WorkspaceCreationFooter(store: store)
    }
    .padding(20)
    .frame(width: 680)
    .onAppear { store.send(.onAppear) }
  }

  private var header: some View {
    VStack(alignment: .leading, spacing: 2) {
      Text(store.isAddMode ? "Add Repository" : "New Workspace").font(.headline)
      Text(
        store.isAddMode
          ? "Check out one more repository into \(store.titleDraft)."
          : "One folder holding checkouts of several repositories, for a task that spans them."
      )
      .font(.caption)
      .foregroundStyle(.secondary)
    }
  }

  private var workspaceFields: some View {
    HStack(alignment: .top, spacing: 12) {
      field("Title") {
        TextField(
          "Checkout Flow",
          text: Binding(get: { store.titleDraft }, set: { store.send(.titleChanged($0)) })
        )
        .textFieldStyle(.roundedBorder)
      }
      field("Folder") {
        HStack(spacing: 8) {
          TextField(
            "~/.codans/workspaces/checkout-flow",
            text: Binding(get: { store.rootPathDraft }, set: { store.send(.rootPathChanged($0)) })
          )
          .textFieldStyle(.roundedBorder)
          .font(.callout.monospaced())
          Button("Choose…") { store.send(.browseRootTapped) }
        }
        ForEach(Array(store.rootIssues.enumerated()), id: \.offset) { _, issue in
          Text(issue.message)
            .font(.caption)
            .foregroundStyle(issue.severity == .blocking ? .red : .secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
      }
    }
    .disabled(store.creation != .idle)
  }

  private var memberList: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 2) {
        if store.members.isEmpty {
          Text(
            store.isAddMode ? "Add the repository above." : "Add at least \(WorkspacePlan.minimumMembers) repositories."
          )
          .font(.caption)
          .foregroundStyle(.secondary)
          .padding(8)
        }
        ForEach(store.members) { member in
          let issues = store.state.issues(for: member)
          let isExpanded = store.expandedMemberID == member.id
          VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 4) {
              WorkspaceMemberRow(
                member: member,
                issues: issues,
                isExpanded: isExpanded,
                isCreating: store.creation != .idle,
                send: { store.send(.member(member.id, $0)) })
              if store.creation == .idle {
                Button {
                  store.send(.member(member.id, .remove))
                } label: {
                  Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("Remove \(member.name)")
                }
                .buttonStyle(.plain)
              }
            }
            if isExpanded {
              WorkspaceMemberDetail(
                member: member,
                issues: issues,
                sharedBranch: store.sharedBranch,
                isDisabled: store.creation != .idle,
                send: { store.send(.member(member.id, $0)) })
            }
          }
          .background(
            isExpanded ? Color.accentColor.opacity(0.06) : Color.clear,
            in: RoundedRectangle(cornerRadius: 6))
        }
      }
    }
    .frame(maxHeight: 300)
    .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.separator))
  }

  private var sharedBranchRow: some View {
    HStack(alignment: .top, spacing: 12) {
      field("Branch for all") {
        TextField(
          "feat/checkout-flow",
          text: Binding(get: { store.sharedBranch }, set: { store.send(.sharedBranchChanged($0)) })
        )
        .textFieldStyle(.roundedBorder)
        .font(.callout.monospaced())
      }
      field("From") {
        RefPickerButton(
          selection: store.sharedBaseRef,
          options: sharedBaseRefOptions,
          allowsDefault: true,
          onSelect: { store.send(.sharedBaseRefChanged($0)) })
        Text("Rows with their own branch or base keep them.")
          .font(.caption)
          .foregroundStyle(.secondary)
      }
    }
    .disabled(store.creation != .idle)
  }

  /// Refs every loaded repository has, so the shared pick applies everywhere.
  private var sharedBaseRefOptions: [BranchRefOption] {
    let inventories = store.members.compactMap { $0.refs.inventory }
    guard let first = inventories.first else { return [] }
    let common = inventories.dropFirst().reduce(Set(first.local + first.remote)) { acc, inventory in
      acc.intersection(inventory.local + inventory.remote)
    }
    return common.sorted { $0.localizedStandardCompare($1) == .orderedAscending }.map { ref in
      BranchRefOption(shortName: ref, isRemote: ref.contains("/") && first.remote.contains(ref))
    }
  }

  private func field<Content: View>(_ label: String, @ViewBuilder content: () -> Content) -> some View {
    VStack(alignment: .leading, spacing: 4) {
      Text(label).font(.callout)
      content()
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }
}

/// Extracted so the sidebar's modifier chain stays under the type-checker
/// limit; an inline `.sheet` with binding + scope closures pushes it over.
struct CreateWorkspaceSheetPresenter: ViewModifier {
  @Bindable var store: StoreOf<HierarchySidebarFeature>

  func body(content: Content) -> some View {
    content.sheet(
      isPresented: Binding(
        get: { store.createWorkspaceSheet != nil },
        set: { isPresented in
          if !isPresented {
            store.send(.createWorkspaceSheet(.cancelButtonTapped))
          }
        }
      )
    ) {
      if let childStore = store.scope(
        state: \.createWorkspaceSheet,
        action: \.createWorkspaceSheet
      ) {
        CreateWorkspaceSheet(store: childStore)
          .interactiveDismissDisabled(store.createWorkspaceSheet?.creation.isBusy ?? false)
      }
    }
  }
}

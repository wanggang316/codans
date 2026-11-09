import CodansCore
import ComposableArchitecture
import SwiftUI

/// SwiftUI sheet for `CreateWorktreeFeature`, on the shared `FormSheet`
/// frame: the branch name with its note, the worktree options, and the agent
/// to launch. The first two sections share their rows with the New Agent
/// dialog so the two read the same.
struct CreateWorktreeSheet: View {
  @Bindable var store: StoreOf<CreateWorktreeFeature>

  var body: some View {
    FormSheet(
      "New Worktree",
      primaryTitle: "Create",
      canSubmit: canCreate,
      onCancel: { store.send(.cancelButtonTapped) },
      onSubmit: { store.send(.createButtonTapped) },
      content: {
        Section {
          TextField(
            "Branch name",
            text: Binding(
              get: { store.branchNameDraft },
              set: { store.send(.branchDraftChanged($0)) },
            ),
            prompt: Text(verbatim: "feature/login"),
          )
        } footer: {
          WorktreeBranchNoteFooter(note: store.branchNote)
        }
        Section {
          WorktreeOptionRows(form: store)
        }
        // Launched once the worktree exists and its setup script has run.
        // Hidden when no agent profile is offered — a None-only picker
        // says nothing.
        if !store.agentProfiles.isEmpty {
          Section {
            launchAgentPicker
          }
        }
      },
    )
    .onAppear { store.send(.onAppear) }
  }

  private var launchAgentPicker: some View {
    Picker(
      "Launch agent",
      selection: Binding(
        get: { store.launchAgentProfileID },
        set: { store.send(.launchAgentSelected($0)) },
      ),
    ) {
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

  private var canCreate: Bool {
    store.validationError == nil
      && !store.branchNameDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      && store.selectedBaseRef != nil
      && !store.isAtPendingCap
      // A name collision blocks Create — the branch note explains why the
      // name is taken; the user resolves it themselves.
      && store.branchCollisionKind == .none
  }
}

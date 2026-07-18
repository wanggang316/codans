import CodansCore
import ComposableArchitecture
import SwiftUI

/// SwiftUI sheet for `CreateWorktreeFeature`. Minimal form: branch
/// name + live validator, base-ref dropdown, three toggles, optional
/// streaming progress log, error banner, and Cancel / Create footer.
struct CreateWorktreeSheet: View {
  @Bindable var store: StoreOf<CreateWorktreeFeature>

  var body: some View {
    VStack(alignment: .leading, spacing: 14) {
      Text("Create Worktree")
        .font(.headline)

      if store.currentPendingCountForProject >= 8 {
        Text(CreateWorktreeFeature.capMessage)
          .font(.caption)
          .foregroundStyle(.orange)
          .frame(maxWidth: .infinity, alignment: .leading)
      }

      VStack(alignment: .leading, spacing: 4) {
        Text("Branch name").font(.callout)
        TextField(
          "feature/login",
          text: Binding(
            get: { store.branchNameDraft },
            set: { store.send(.branchDraftChanged($0)) }
          )
        )
        .textFieldStyle(.roundedBorder)
        if let error = store.validationError {
          Text(error)
            .font(.caption)
            .foregroundStyle(.red)
        }
      }

      // Conflict note — visible only while the draft collides with an
      // existing branch. Purely informational: it names the branch's REAL
      // casing and the REASON the name is taken, then leaves the fix to
      // the user (Create stays disabled meanwhile) — pick a different
      // name, or clean up / switch to the existing branch outside the
      // sheet. There is deliberately no in-app resolution machinery.
      if store.branchCollisionKind != .none {
        Text(collisionNote)
          .font(.caption)
          .foregroundStyle(.orange)
          .fixedSize(horizontal: false, vertical: true)
          .frame(maxWidth: .infinity, alignment: .leading)
      }

      VStack(alignment: .leading, spacing: 4) {
        Text("Base ref").font(.callout)
        if store.loadingOptions {
          ProgressView()
            .controlSize(.small)
        } else {
          Picker(
            "",
            selection: Binding(
              get: { store.selectedBaseRef ?? "" },
              set: { store.send(.baseRefSelected($0.isEmpty ? nil : $0)) }
            )
          ) {
            ForEach(store.baseRefOptions, id: \.self) { ref in
              Text(ref).tag(ref)
            }
          }
          .labelsHidden()
        }
      }

      VStack(alignment: .leading, spacing: 6) {
        Toggle(
          "Fetch origin before creating worktree",
          isOn: Binding(
            get: { store.fetchOrigin },
            set: { store.send(.fetchOriginToggled($0)) }
          )
        )
        Toggle(
          "Copy ignored files",
          isOn: Binding(
            get: { store.copyIgnored },
            set: { store.send(.copyIgnoredToggled($0)) }
          )
        )
        Toggle(
          "Copy untracked files",
          isOn: Binding(
            get: { store.copyUntracked },
            set: { store.send(.copyUntrackedToggled($0)) }
          )
        )
      }

      if let error = store.submitError {
        Text(error)
          .font(.caption)
          .foregroundStyle(.red)
          .frame(maxWidth: .infinity, alignment: .leading)
      }

      HStack {
        Spacer()
        Button("Cancel") {
          store.send(.cancelButtonTapped)
        }
        .keyboardShortcut(.cancelAction)

        Button("Create") {
          store.send(.createButtonTapped)
        }
        .keyboardShortcut(.defaultAction)
        .disabled(
          store.validationError != nil
            || store.branchNameDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || store.selectedBaseRef == nil
            || store.currentPendingCountForProject >= 8
            // A name collision blocks Create — the conflict note explains
            // why the name is taken; the user resolves it themselves.
            || store.branchCollisionKind != .none
        )
      }
    }
    .padding(20)
    .frame(width: 420)
    .onAppear { store.send(.onAppear) }
  }

  /// The conflict note's copy: states the REASON the drafted name is
  /// unavailable, naming the EXISTING ref's real casing (the draft may
  /// differ only by case) so the user's follow-up targets the branch git
  /// actually has.
  private var collisionNote: String {
    switch store.branchCollisionKind {
    case .checkedOut:
      let branch = store.checkedOutOwner?.branch ?? store.sanitizedBranchDraft
      let holder =
        store.checkedOutOwner.map { "the worktree \"\($0.worktreeName)\"" }
        ?? "another worktree"
      return
        "\"\(branch)\" is already checked out by \(holder) — git allows a branch to be "
        + "checked out by only one worktree at a time. Choose a different name, or work "
        + "in that worktree instead."
    case .dangling:
      let real = store.danglingRealName ?? store.sanitizedBranchDraft
      return
        "A local branch named \"\(real)\" already exists without a worktree — it was "
        + "likely kept when its worktree was removed. Choose a different name, or delete "
        + "the branch (git branch -D \"\(real)\") and reopen this dialog."
    case .archivedWorktree:
      let branch = store.archivedOwner?.branch ?? store.sanitizedBranchDraft
      let name = store.archivedOwner?.worktreeName ?? branch
      return
        "\"\(branch)\" belongs to the archived worktree \"\(name)\" — it's hidden from "
        + "the sidebar, but its branch and files still exist. Unarchive or remove it via "
        + "the Project's ⋯ menu → \"Archived Worktrees…\", or choose a different name."
    case .none:
      return ""
    }
  }
}

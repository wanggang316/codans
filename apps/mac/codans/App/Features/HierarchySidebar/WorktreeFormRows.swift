import ComposableArchitecture
import SwiftUI

/// The one note under the branch-name row. Errors read red; collisions and
/// the pending cap read orange because the user can fix them by choosing
/// another name or waiting.
struct WorktreeBranchNote: Equatable {
  let text: String
  let isError: Bool
}

extension CreateWorktreeFeature.State {
  /// The per-project cap on queued creations (8) is reached; Create stays
  /// disabled and the branch note says why.
  var isAtPendingCap: Bool { currentPendingCountForProject >= 8 }

  /// The branch row's note: at most one, most specific first. Shared by the
  /// New Worktree sheet and the New Agent dialog so the two cannot drift.
  var branchNote: WorktreeBranchNote? {
    if let validationError { return WorktreeBranchNote(text: validationError, isError: true) }
    if branchCollisionKind != .none { return WorktreeBranchNote(text: collisionNote, isError: false) }
    if isAtPendingCap { return WorktreeBranchNote(text: CreateWorktreeFeature.capMessage, isError: false) }
    if let submitError { return WorktreeBranchNote(text: submitError, isError: true) }
    return nil
  }

  /// The conflict note's copy: states the REASON the drafted name is
  /// unavailable, naming the EXISTING ref's real casing (the draft may
  /// differ only by case) so the user's follow-up targets the branch git
  /// actually has. Purely informational: Create stays disabled and the user
  /// resolves the conflict outside the sheet.
  var collisionNote: String {
    switch branchCollisionKind {
    case .checkedOut:
      let branch = checkedOutOwner?.branch ?? sanitizedBranchDraft
      let holder =
        checkedOutOwner.map { "the worktree \"\($0.worktreeName)\"" }
        ?? "another worktree"
      return
        "\"\(branch)\" is already checked out by \(holder) — git allows a branch to be "
        + "checked out by only one worktree at a time. Choose a different name, or work "
        + "in that worktree instead."
    case .dangling:
      let real = danglingRealName ?? sanitizedBranchDraft
      return
        "A local branch named \"\(real)\" already exists without a worktree — it was "
        + "likely kept when its worktree was removed. Choose a different name, or delete "
        + "the branch (git branch -D \"\(real)\") and reopen this dialog."
    case .archivedWorktree:
      let branch = archivedOwner?.branch ?? sanitizedBranchDraft
      let name = archivedOwner?.worktreeName ?? branch
      return
        "\"\(branch)\" belongs to the archived worktree \"\(name)\" — it's hidden from "
        + "the sidebar, but its branch and files still exist. Unarchive or remove it via "
        + "the Project's ⋯ menu → \"Archived Worktrees…\", or choose a different name."
    case .none:
      return ""
    }
  }
}

/// Footer of the branch-name section: the form's `branchNote`, if any.
struct WorktreeBranchNoteFooter: View {
  let note: WorktreeBranchNote?

  var body: some View {
    if let note {
      Text(note.text)
        .font(.caption)
        .foregroundStyle(note.isError ? .red : .orange)
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
  }
}

/// Grouped-form rows for a new worktree's options: base ref (a small spinner
/// while the options load), fetch origin, and the copy toggles.
struct WorktreeOptionRows: View {
  let form: StoreOf<CreateWorktreeFeature>

  var body: some View {
    if form.loadingOptions {
      LabeledContent("Base ref") {
        ProgressView().controlSize(.small)
      }
    } else {
      Picker(
        "Base ref",
        selection: Binding(
          get: { form.selectedBaseRef ?? "" },
          set: { form.send(.baseRefSelected($0.isEmpty ? nil : $0)) },
        ),
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
        set: { form.send(.fetchOriginToggled($0)) },
      ),
    )
    // Copying is a local streaming-create capability; a server project
    // runs plain `git worktree add` on the host, so the toggles would be
    // silent no-ops there.
    if !form.isRemote {
      Toggle(
        "Copy ignored files",
        isOn: Binding(
          get: { form.copyIgnored },
          set: { form.send(.copyIgnoredToggled($0)) },
        ),
      )
      Toggle(
        "Copy untracked files",
        isOn: Binding(
          get: { form.copyUntracked },
          set: { form.send(.copyUntrackedToggled($0)) },
        ),
      )
    }
  }
}

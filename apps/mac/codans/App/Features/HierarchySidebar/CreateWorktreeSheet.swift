import ComposableArchitecture
import SwiftUI
import CodansCore

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

      // Inline resolution control — visible only when a branch collision exists.
      switch store.branchCollisionKind {
      case .checkedOut:
        // Only Rename is viable; offer no picker — just explain why.
        Text(
          "\"\(store.sanitizedBranchDraft)\" is checked out in another worktree — reuse/recreate isn't possible; rename it."
        )
        .font(.caption)
        .foregroundStyle(.secondary)
      case .dangling:
        // All three resolutions are valid for a dangling branch.
        VStack(alignment: .leading, spacing: 4) {
          Text("Conflict resolution").font(.callout)
          Picker(
            "",
            selection: Binding(
              get: { store.selectedResolution },
              set: { store.send(.resolutionChanged($0)) }
            )
          ) {
            Text("Rename (add numeric suffix)").tag(BranchConflictResolution.rename)
            Text("Reuse existing commits").tag(BranchConflictResolution.reuse)
            Text("Recreate from base ref").tag(BranchConflictResolution.recreate)
          }
          .labelsHidden()
          .pickerStyle(.menu)
        }
      case .none:
        EmptyView()
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
        )
      }
    }
    .padding(20)
    .frame(width: 420)
    .onAppear { store.send(.onAppear) }
  }
}

import CodansCore
import ComposableArchitecture
import SwiftUI

/// Sheet for `CreateWorkspaceFeature`. Layout mirrors `CloneRepoSheet`:
/// header, optional error, fields, footer buttons.
struct CreateWorkspaceSheet: View {
  @Bindable var store: StoreOf<CreateWorkspaceFeature>

  var body: some View {
    VStack(alignment: .leading, spacing: 14) {
      Text("New Workspace").font(.headline)
      Text("One folder holding checkouts of several repositories, for a task that spans them.")
        .font(.caption)
        .foregroundStyle(.secondary)
      if let error = store.errorMessage {
        Text(error)
          .font(.caption)
          .foregroundStyle(.red)
          .textSelection(.enabled)
          .frame(maxWidth: .infinity, alignment: .leading)
      }

      field("Title") {
        TextField(
          "Checkout Flow",
          text: Binding(get: { store.titleDraft }, set: { store.send(.titleChanged($0)) })
        )
        .textFieldStyle(.roundedBorder)
        .disabled(store.isCreating)
      }

      field("Folder") {
        HStack(spacing: 8) {
          TextField(
            "~/.codans/workspaces/checkout-flow",
            text: Binding(get: { store.rootPathDraft }, set: { store.send(.rootPathChanged($0)) })
          )
          .textFieldStyle(.roundedBorder)
          .disabled(store.isCreating)
          Button("Choose…") { store.send(.browseRootTapped) }
            .disabled(store.isCreating)
        }
      }

      field("Repositories") {
        repositoriesList
      }

      HStack(alignment: .top, spacing: 12) {
        field("Branch") {
          TextField(
            "feat/checkout-flow",
            text: Binding(get: { store.branchDraft }, set: { store.send(.branchChanged($0)) })
          )
          .textFieldStyle(.roundedBorder)
          .disabled(store.isCreating)
        }
        field("Base ref") {
          TextField(
            "default branch",
            text: Binding(get: { store.baseRefDraft }, set: { store.send(.baseRefChanged($0)) })
          )
          .textFieldStyle(.roundedBorder)
          .disabled(store.isCreating || store.useExistingBranch)
        }
      }
      Toggle(
        "Check out an existing branch instead of creating one",
        isOn: Binding(
          get: { store.useExistingBranch }, set: { store.send(.useExistingBranchChanged($0)) })
      )
      .font(.callout)
      .disabled(store.isCreating)

      if store.isCreating {
        HStack(spacing: 8) {
          ProgressView().controlSize(.small)
          Text("Creating checkouts…").font(.caption).foregroundStyle(.secondary)
        }
      }

      HStack {
        Spacer()
        Button("Cancel") { store.send(.cancelButtonTapped) }
          .keyboardShortcut(.cancelAction)
          .disabled(store.isCreating)
        Button("Create") { store.send(.createButtonTapped) }
          .keyboardShortcut(.defaultAction)
          .disabled(!store.canCreate)
      }
    }
    .padding(20)
    .frame(width: 520)
  }

  private var repositoriesList: some View {
    VStack(alignment: .leading, spacing: 4) {
      if store.candidates.isEmpty && store.localRepos.isEmpty {
        Text("No local git projects are open. Add repositories from disk below.")
          .font(.caption)
          .foregroundStyle(.secondary)
      }
      ForEach(store.candidates) { candidate in
        Toggle(
          isOn: Binding(
            get: { store.selectedCandidateIDs.contains(candidate.id) },
            set: { _ in store.send(.candidateToggled(candidate.id)) })
        ) {
          HStack(spacing: 6) {
            Text(candidate.name)
            Text(candidate.gitRoot)
              .font(.caption)
              .foregroundStyle(.secondary)
              .lineLimit(1)
              .truncationMode(.middle)
          }
        }
        .toggleStyle(.checkbox)
        .disabled(store.isCreating)
      }
      ForEach(store.localRepos, id: \.self) { path in
        HStack(spacing: 6) {
          Image(systemName: "folder")
            .foregroundStyle(.secondary)
            .accessibilityHidden(true)
          Text((path as NSString).lastPathComponent)
          Text(path)
            .font(.caption)
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .truncationMode(.middle)
          Spacer()
          Button {
            store.send(.removeLocalRepo(path))
          } label: {
            Image(systemName: "xmark.circle.fill")
              .foregroundStyle(.secondary)
              .accessibilityLabel("Remove \((path as NSString).lastPathComponent)")
          }
          .buttonStyle(.plain)
          .disabled(store.isCreating)
        }
      }
      Button {
        store.send(.addLocalRepoTapped)
      } label: {
        Label("Add Local Repository…", systemImage: "plus")
      }
      .buttonStyle(.link)
      .disabled(store.isCreating)
      Text(
        "At least \(WorkspacePlan.minimumMembers) repositories; each is checked out into the folder under its own name."
      )
      .font(.caption)
      .foregroundStyle(.secondary)
    }
  }

  private func field<Content: View>(_ label: String, @ViewBuilder content: () -> Content) -> some View {
    VStack(alignment: .leading, spacing: 4) {
      Text(label).font(.callout)
      content()
    }
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
          .interactiveDismissDisabled(store.createWorkspaceSheet?.isCreating ?? false)
      }
    }
  }
}

import CodansCore
import ComposableArchitecture
import SwiftUI

/// The dialog behind the sheet's Add buttons and a row's Edit button, as a
/// grouped form like the sheet it opens from. The first section is where
/// the project comes from: an open project (fixed), a folder on this Mac
/// (with the picker to choose another), or a URL and the folder it is
/// cloned into. The second is how it is checked out and the folder it gets
/// in the workspace. Add / Save puts it in the list.
struct WorkspaceMemberEditorSheet: View {
  let store: StoreOf<CreateWorkspaceFeature>
  @FocusState private var isURLFocused: Bool

  var body: some View {
    if let editor = store.editor {
      VStack(spacing: 0) {
        Form {
          sourceSection(editor)
          if let draft = editor.draft {
            checkoutSection(draft)
          }
        }
        .formStyle(.grouped)
        .scrollBounceBehavior(.basedOnSize)
        bar(editor)
      }
      .frame(width: 500)
      .frame(maxHeight: 640)
      .onAppear {
        if editor.kind == .remote { isURLFocused = true }
      }
    }
  }

  // MARK: Source

  private func sourceSection(_ editor: MemberEditor) -> some View {
    Section {
      switch editor.kind {
      case .folder:
        folderRow(editor)
      case .remote:
        urlField(editor)
        if let draft = editor.draft, case .remote(_, let destination) = draft.source {
          cloneDestinationRow(draft, destination: destination)
        }
      case .project, .edit:
        if let draft = editor.draft {
          LabeledContent {
            Text(draft.source.title)
          } label: {
            Text("Repository")
            Text(draft.source.location)
              .lineLimit(1)
              .truncationMode(.middle)
              .help(draft.source.location)
          }
          if case .remote(_, let destination) = draft.source {
            cloneDestinationRow(draft, destination: destination)
          }
        }
      }
    } header: {
      Text(title(editor))
      Text(subtitle(editor))
    } footer: {
      if let issue = editor.sourceIssue {
        Text(issue)
          .foregroundStyle(.red)
          .fixedSize(horizontal: false, vertical: true)
          .frame(maxWidth: .infinity, alignment: .leading)
      }
    }
    .headerProminence(.increased)
  }

  private func title(_ editor: MemberEditor) -> String {
    let name = editor.draft?.source.title ?? "Project"
    switch editor.kind {
    case .project: return "Add \(name)"
    case .folder: return "Add Folder"
    case .remote: return "Add Remote Repository"
    case .edit: return "Edit \(name)"
    }
  }

  private func subtitle(_ editor: MemberEditor) -> String {
    switch editor.kind {
    case .project, .edit: return "How this project is checked out in the workspace."
    case .folder: return "A repository folder on this Mac."
    case .remote: return "Cloned to this Mac, then checked out like a local repository."
    }
  }

  /// The picked folder, like the sheet's Location row, with the picker to
  /// choose another. A folder of an open project becomes that project.
  private func folderRow(_ editor: MemberEditor) -> some View {
    LabeledContent {
      HStack(spacing: 8) {
        if editor.isResolvingSource {
          ProgressView().controlSize(.small)
        }
        if let draft = editor.draft {
          PathText(path: draft.source.gitRoot)
        } else {
          Text("None")
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .trailing)
        }
        Button("Choose…") {
          store.send(.editor(.chooseFolderTapped))
        }
      }
    } label: {
      Text("Folder")
      if let draft = editor.draft, case .project(_, let name, _) = draft.source {
        Text("Open in codans as \(name).")
      }
    }
  }

  /// What checking out a remote branch will do, when it is not obvious.
  private func trackingNote(_ draft: MemberDraft) -> String? {
    guard draft.existingRefIsRemote, let branch = draft.remoteRefBranch else { return nil }
    return "Creates a local branch \u{201C}\(branch)\u{201D} tracking it."
  }

  private func urlField(_ editor: MemberEditor) -> some View {
    TextField(
      "URL",
      text: Binding(get: { editor.urlText }, set: { store.send(.editor(.urlChanged($0))) }),
      prompt: Text("git@github.com:org/repo.git")
    )
    .focused($isURLFocused)
    .onSubmit { store.send(.editor(.urlSubmitted)) }
  }

  private func cloneDestinationRow(_ draft: MemberDraft, destination: String) -> some View {
    LabeledContent {
      HStack(spacing: 6) {
        PathText(path: destination)
        Button {
          store.send(.member(draft.id, .chooseCloneDestinationTapped))
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

  // MARK: Checkout

  private func checkoutSection(_ draft: MemberDraft) -> some View {
    Section {
      Picker("Checkout", selection: binding(draft, \.mode, { .modeChanged($0) })) {
        ForEach(MemberDraft.CheckoutMode.allCases, id: \.self) { mode in
          Text(mode.title).tag(mode)
        }
      }
      switch draft.mode {
      case .newBranch:
        newBranchRows(draft)
      case .existing:
        existingBranchRows(draft)
      }
      LabeledContent {
        TextField("Folder name", text: binding(draft, \.name, { .nameChanged($0) }))
          .labelsHidden()
      } label: {
        Text("Folder name")
        Text("Inside the workspace folder.")
      }
    } footer: {
      VStack(alignment: .leading, spacing: 2) {
        refsStatus(draft)
        IssueList(issues: listedIssues(draft))
      }
    }
  }

  @ViewBuilder
  private func newBranchRows(_ draft: MemberDraft) -> some View {
    let defaultBranch = store.state.defaultBranch
    LabeledContent {
      TextField(
        "Branch",
        text: binding(draft, \.branchOverride, { .branchOverrideChanged($0) }),
        prompt: Text(defaultBranch.isEmpty ? "branch-name" : defaultBranch)
      )
      .labelsHidden()
    } label: {
      Text("Branch")
      if !store.isAddMode {
        Text("Empty uses the workspace title.")
      }
    }
    WorkspaceRefPicker(
      title: "Based on",
      refs: draft.refs,
      selection: draft.baseRef,
      placeholder: draft.refs.inventory?.defaultBaseRef.map { "Default (\($0))" } ?? "Default branch",
      includeLocal: true,
      includeRemote: true,
      onSelect: { send(draft, .baseRefChanged($0)) })
  }

  /// One list of the repository's branches, local and remote. A remote one
  /// is checked out as a local branch that tracks it, so the row says so,
  /// and a local branch of that name brings up the Keep / Reset choice.
  @ViewBuilder
  private func existingBranchRows(_ draft: MemberDraft) -> some View {
    WorkspaceRefPicker(
      title: "Branch",
      refs: draft.refs,
      selection: draft.existingRef,
      placeholder: "Choose a branch",
      includeLocal: true,
      includeRemote: true,
      subtitle: draft.hasLocalConflict ? nil : trackingNote(draft),
      onSelect: { send(draft, .existingRefChanged($0)) })
    if draft.hasLocalConflict, let branch = draft.remoteRefBranch {
      Picker(selection: binding(draft, \.localConflict, { .localConflictChanged($0) })) {
        Text("Keep local branch").tag(MemberDraft.LocalConflictResolution.keepLocal)
        Text("Reset to \(draft.existingRef ?? "remote")").tag(MemberDraft.LocalConflictResolution.resetToRemote)
      } label: {
        Text("Local branch")
        Text("A local branch named \u{201C}\(branch)\u{201D} already exists.")
      }
    }
  }

  /// The dialog's findings without the source's, which head the first
  /// section, and without a refs failure, which `refsStatus` shows with
  /// Retry.
  private func listedIssues(_ draft: MemberDraft) -> [MemberIssue] {
    var issues = store.state.editorIssues
    if let sourceIssue = store.editor?.sourceIssue {
      issues.removeAll { $0.message == sourceIssue }
    }
    if case .failed(let message) = draft.refs {
      issues.removeAll { $0.message == message }
    }
    return issues
  }

  @ViewBuilder
  private func refsStatus(_ draft: MemberDraft) -> some View {
    switch draft.refs {
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
          .foregroundStyle(draft.mode == .existing ? .red : .orange)
          .fixedSize(horizontal: false, vertical: true)
        Button("Retry") { send(draft, .retryRefsTapped) }
          .buttonStyle(.link)
      }
    }
  }

  // MARK: Bar

  private func bar(_ editor: MemberEditor) -> some View {
    HStack(spacing: 8) {
      if editor.isResolvingSource {
        ProgressView().controlSize(.small)
        Text("Checking the folder…")
          .foregroundStyle(.secondary)
      } else if let hint = store.state.editorIssues.first(where: { $0.severity == .incomplete }) {
        Text(hint.message)
          .foregroundStyle(.secondary)
          .lineLimit(2)
      }
      Spacer(minLength: 12)
      Button("Cancel", role: .cancel) {
        store.send(.editor(.cancelTapped))
      }
      .keyboardShortcut(.cancelAction)
      Button(editor.isNew ? "Add" : "Save") {
        store.send(.editor(.saveTapped))
      }
      .keyboardShortcut(.defaultAction)
      .disabled(!store.state.canSaveEditor)
    }
    .padding(.horizontal, 20)
    .padding(.top, 4)
    .padding(.bottom, 20)
  }

  // MARK: Plumbing

  private func send(_ draft: MemberDraft, _ action: CreateWorkspaceFeature.Action.MemberAction) {
    store.send(.member(draft.id, action))
  }

  private func binding<Value>(
    _ draft: MemberDraft,
    _ keyPath: KeyPath<MemberDraft, Value>,
    _ action: @escaping (Value) -> CreateWorkspaceFeature.Action.MemberAction
  ) -> Binding<Value> {
    // Read through the store so the field follows the draft as it changes.
    let id = draft.id
    return Binding(
      get: { store.editor?.draft?[keyPath: keyPath] ?? draft[keyPath: keyPath] },
      set: { store.send(.member(id, action($0))) })
  }
}

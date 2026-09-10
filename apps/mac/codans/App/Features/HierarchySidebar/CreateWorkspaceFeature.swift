import CodansCore
import ComposableArchitecture
import Foundation

/// Reducer behind the "New Workspace" sheet reached from the sidebar's Add
/// menu and the command palette. Collects a title, the folder, the member
/// repositories (registered local Projects and any local repositories picked
/// from disk), and one branch applied to every member, then hands a
/// `WorkspacePlan` to `WorkspaceClient`, which does every disk and git step.
/// Its responsibility ends at `delegate(.created(projectID))`; the client
/// has already registered and reconciled the workspace by then.
@Reducer
struct CreateWorkspaceFeature {
  /// A registered local git Project offered as a member.
  struct Candidate: Equatable, Identifiable, Sendable {
    let id: ProjectID
    let name: String
    let gitRoot: String
  }

  @ObservableState
  struct State: Equatable {
    var candidates: [Candidate]
    var selectedCandidateIDs: Set<ProjectID> = []
    /// Repository roots picked from disk, in pick order.
    var localRepos: [String] = []
    var titleDraft: String = ""
    var rootPathDraft: String = ""
    /// Set once the user edits the folder by hand so title edits stop
    /// re-deriving it out from under them.
    var rootPathEditedManually: Bool = false
    var branchDraft: String = ""
    var branchEditedManually: Bool = false
    var baseRefDraft: String = ""
    var useExistingBranch: Bool = false
    var isCreating: Bool = false
    /// Validation or creation failure, rendered in the sheet header.
    var errorMessage: String?

    init(candidates: [Candidate]) {
      self.candidates = candidates
    }

    var memberCount: Int { selectedCandidateIDs.count + localRepos.count }

    var canCreate: Bool {
      !isCreating
        && !titleDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        && !branchDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        && memberCount >= WorkspacePlan.minimumMembers
    }

    /// Members in sidebar order for registered Projects, then picked
    /// repositories in pick order. Folder names come from the repository
    /// folder; a clash surfaces as a plan validation error.
    var members: [WorkspacePlan.Member] {
      let branch = branchDraft.trimmingCharacters(in: .whitespacesAndNewlines)
      let baseRef = baseRefDraft.trimmingCharacters(in: .whitespacesAndNewlines)
      let checkout: WorkspaceCheckout =
        useExistingBranch
        ? .existingBranch(branch)
        : .newBranch(branch: branch, baseRef: baseRef.isEmpty ? nil : baseRef)
      let fromProjects = candidates.filter { selectedCandidateIDs.contains($0.id) }.map { candidate in
        WorkspacePlan.Member(
          name: (candidate.gitRoot as NSString).lastPathComponent,
          sourceGitRoot: candidate.gitRoot,
          checkout: checkout)
      }
      let fromDisk = localRepos.map { root in
        WorkspacePlan.Member(
          name: (root as NSString).lastPathComponent, sourceGitRoot: root, checkout: checkout)
      }
      return fromProjects + fromDisk
    }

    var plan: WorkspacePlan {
      WorkspacePlan(
        title: titleDraft.trimmingCharacters(in: .whitespacesAndNewlines),
        rootPath: rootPathDraft.trimmingCharacters(in: .whitespacesAndNewlines),
        members: members)
    }
  }

  enum Action: Equatable {
    case titleChanged(String)
    case rootPathChanged(String)
    case browseRootTapped
    case browseRootPicked(URL?)
    case candidateToggled(ProjectID)
    case addLocalRepoTapped
    case localRepoPicked(URL?)
    case localRepoResolved(gitRoot: String?, picked: String)
    case removeLocalRepo(String)
    case branchChanged(String)
    case baseRefChanged(String)
    case useExistingBranchChanged(Bool)
    case createButtonTapped
    case createFailed(String)
    case createSucceeded(ProjectID)
    case cancelButtonTapped
    case delegate(Delegate)

    @CasePathable
    enum Delegate: Equatable {
      case dismissed
      /// The workspace is on disk, registered, and reconciled.
      case created(ProjectID)
    }
  }

  @Dependency(WorkspaceClient.self) private var workspaceClient
  @Dependency(FolderPickerClient.self) private var folderPicker
  @Dependency(GitWorktreeCLI.self) private var gitCLI

  var body: some Reducer<State, Action> {
    Reduce { state, action in
      switch action {
      case .titleChanged(let title):
        state.titleDraft = title
        // Folder and branch follow the title until taken over by hand.
        let slug = WorkspaceLayout.folderName(forTitle: title)
        if !state.rootPathEditedManually {
          state.rootPathDraft =
            title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? ""
            : WorkspaceLayout.defaultWorkspacesDirectory()
              .appending(path: slug, directoryHint: .isDirectory).path
        }
        if !state.branchEditedManually {
          state.branchDraft = title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "" : slug
        }
        return .none

      case .rootPathChanged(let path):
        state.rootPathDraft = path
        state.rootPathEditedManually = true
        return .none

      case .browseRootTapped:
        return .run { [picker = folderPicker] send in
          let url = await picker.pick("Choose Workspace Folder")
          await send(.browseRootPicked(url))
        }

      case .browseRootPicked(let url):
        guard let url else { return .none }
        // The picker returns a PARENT folder; append the slug so the user
        // lands on a ready-to-confirm destination.
        let slug = WorkspaceLayout.folderName(forTitle: state.titleDraft)
        state.rootPathDraft = url.appending(path: slug).path(percentEncoded: false)
        state.rootPathEditedManually = true
        return .none

      case .candidateToggled(let id):
        if state.selectedCandidateIDs.contains(id) {
          state.selectedCandidateIDs.remove(id)
        } else {
          state.selectedCandidateIDs.insert(id)
        }
        return .none

      case .addLocalRepoTapped:
        return .run { [picker = folderPicker] send in
          let url = await picker.pick("Add Local Repository")
          await send(.localRepoPicked(url))
        }

      case .localRepoPicked(let url):
        guard let url else { return .none }
        let picked = url.path(percentEncoded: false)
        return .run { [cli = gitCLI] send in
          let gitRoot = try? await cli.discoverGitRoot(candidatePath: picked)
          await send(.localRepoResolved(gitRoot: gitRoot, picked: picked))
        }

      case .localRepoResolved(let gitRoot, let picked):
        guard let gitRoot, !gitRoot.isEmpty else {
          state.errorMessage = "\(picked) is not inside a git repository."
          return .none
        }
        let canonical = HierarchyManager.canonicalPath(gitRoot)
        if state.localRepos.contains(canonical)
          || state.candidates.contains(where: {
            state.selectedCandidateIDs.contains($0.id)
              && HierarchyManager.canonicalPath($0.gitRoot) == canonical
          })
        {
          state.errorMessage = "\(canonical) is already in the list."
          return .none
        }
        state.errorMessage = nil
        state.localRepos.append(canonical)
        return .none

      case .removeLocalRepo(let path):
        state.localRepos.removeAll { $0 == path }
        return .none

      case .branchChanged(let branch):
        state.branchDraft = branch
        state.branchEditedManually = true
        return .none

      case .baseRefChanged(let ref):
        state.baseRefDraft = ref
        return .none

      case .useExistingBranchChanged(let value):
        state.useExistingBranch = value
        return .none

      case .createButtonTapped:
        let plan = state.plan
        let issues = plan.validate()
        guard issues.isEmpty else {
          state.errorMessage = issues.map(\.description).joined(separator: "\n")
          return .none
        }
        state.errorMessage = nil
        state.isCreating = true
        return .run { [client = workspaceClient] send in
          do {
            let projectID = try await client.create(plan)
            await send(.createSucceeded(projectID))
          } catch {
            await send(.createFailed(error.localizedDescription))
          }
        }

      case .createFailed(let message):
        state.isCreating = false
        state.errorMessage = message
        return .none

      case .createSucceeded(let projectID):
        state.isCreating = false
        return .send(.delegate(.created(projectID)))

      case .cancelButtonTapped:
        // Cancelling mid-creation would strand the client's rollback; the
        // sheet disables Cancel while creating, so this only dismisses.
        return .send(.delegate(.dismissed))

      case .delegate:
        return .none
      }
    }
  }
}

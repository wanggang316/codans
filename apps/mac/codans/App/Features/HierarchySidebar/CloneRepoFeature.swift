import ComposableArchitecture
import Foundation

/// Reducer backing the "Clone Repository" sheet reached from the sidebar's
/// Add Project menu. Tracks the remote URL + local destination drafts,
/// the in-flight clone, and a header error message. Its responsibility
/// ends at `delegate(.cloned(localPath:))` — the parent sidebar reducer
/// then runs the same registration path as a picked local folder
/// (dedup check → gitRoot discovery → catalog add → reconcile), so the
/// clone flow stays decoupled from project bookkeeping.
@Reducer
struct CloneRepoFeature {
  @ObservableState
  struct State: Equatable {
    var remoteURLDraft: String = ""
    var localPathDraft: String = ""
    /// Set once the user edits the destination by hand so subsequent
    /// remote-URL edits stop auto-deriving the path out from under them.
    var localPathEditedManually: Bool = false
    var isCloning: Bool = false
    /// Clone failure or validation message, rendered in the sheet header.
    var errorMessage: String?
  }

  enum Action: Equatable {
    case remoteURLChanged(String)
    case localPathChanged(String)
    case browseTapped
    case browseFolderPicked(URL?)
    case cloneButtonTapped
    case cloneFailed(String)
    case cloneSucceeded(localPath: String)
    case cancelButtonTapped
    case delegate(Delegate)

    @CasePathable
    enum Delegate: Equatable {
      case dismissed
      /// Clone finished; carries the on-disk destination. Parent registers
      /// it as a Project via the shared add-folder path.
      case cloned(localPath: String)
    }
  }

  @Dependency(GitWorktreeCLI.self) private var gitCLI
  @Dependency(FolderPickerClient.self) private var folderPicker

  var body: some Reducer<State, Action> {
    Reduce { state, action in
      switch action {
      case .remoteURLChanged(let url):
        state.remoteURLDraft = url
        // Auto-fill the destination from the repo name until the user
        // takes the path over by hand.
        if !state.localPathEditedManually {
          state.localPathDraft = Self.suggestedDestination(forRemoteURL: url)
        }
        return .none

      case .localPathChanged(let path):
        state.localPathDraft = path
        state.localPathEditedManually = true
        return .none

      case .browseTapped:
        return .run { [picker = folderPicker] send in
          let url = await picker.pick("Choose Destination Folder")
          await send(.browseFolderPicked(url))
        }

      case .browseFolderPicked(let url):
        guard let url else { return .none }
        // The picker returns a PARENT folder; append the derived repo name
        // so the user lands on a ready-to-confirm destination.
        let repoName = Self.repoName(fromRemoteURL: state.remoteURLDraft) ?? "repository"
        state.localPathDraft = url.appending(path: repoName).path(percentEncoded: false)
        state.localPathEditedManually = true
        return .none

      case .cloneButtonTapped:
        let remote = state.remoteURLDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        let dest = state.localPathDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !remote.isEmpty else {
          state.errorMessage = "Enter a repository URL."
          return .none
        }
        guard !dest.isEmpty else {
          state.errorMessage = "Choose a local destination path."
          return .none
        }
        let expanded = (dest as NSString).expandingTildeInPath
        guard !FileManager.default.fileExists(atPath: expanded) else {
          state.errorMessage = "A file or folder already exists at \(expanded)."
          return .none
        }
        state.errorMessage = nil
        state.isCloning = true
        return .run { [cli = gitCLI] send in
          do {
            try await cli.clone(remoteURL: remote, destinationPath: expanded)
            await send(.cloneSucceeded(localPath: expanded))
          } catch {
            await send(.cloneFailed(Self.message(for: error)))
          }
        }

      case .cloneFailed(let message):
        state.isCloning = false
        state.errorMessage = message
        return .none

      case .cloneSucceeded(let localPath):
        state.isCloning = false
        return .send(.delegate(.cloned(localPath: localPath)))

      case .cancelButtonTapped:
        return .send(.delegate(.dismissed))

      case .delegate:
        return .none
      }
    }
  }
}

// MARK: - URL parsing helpers

extension CloneRepoFeature {
  /// Best-effort repo name from a clone URL. Strips a trailing slash and
  /// `.git`, then takes the final path segment — handling both URL forms
  /// (`https://host/owner/repo.git`) and scp-style (`git@host:owner/repo`).
  /// Returns nil when nothing usable remains.
  static func repoName(fromRemoteURL raw: String) -> String? {
    var trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return nil }
    if trimmed.hasSuffix("/") { trimmed.removeLast() }
    if trimmed.hasSuffix(".git") { trimmed.removeLast(4) }
    let separator = trimmed.lastIndex(where: { $0 == "/" || $0 == ":" })
    let name = separator.map { String(trimmed[trimmed.index(after: $0)...]) } ?? trimmed
    let cleaned = name.trimmingCharacters(in: .whitespaces)
    return cleaned.isEmpty ? nil : cleaned
  }

  /// Suggested destination under the user's home directory, named after the
  /// repo. Empty string when the URL has no derivable name yet.
  static func suggestedDestination(forRemoteURL raw: String) -> String {
    guard let name = repoName(fromRemoteURL: raw) else { return "" }
    return FileManager.default.homeDirectoryForCurrentUser
      .appending(path: name)
      .path(percentEncoded: false)
  }

  /// Maps a clone error to a user-facing string, preferring git's own
  /// stderr so the reason (auth, unreachable host, existing dir) is exact.
  static func message(for error: Error) -> String {
    guard let cliError = error as? GitCLIError else {
      return "Clone failed: \(error.localizedDescription)"
    }
    switch cliError {
    case .exitCode(_, let stderr):
      let trimmed = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
      return trimmed.isEmpty ? "git clone failed." : trimmed
    case .executableNotFound:
      return "Could not find the git executable."
    case .invalidUTF8:
      return "git produced output that could not be decoded."
    }
  }
}

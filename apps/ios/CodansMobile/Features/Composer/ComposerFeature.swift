import CodansIPC
import ComposableArchitecture
import Foundation

/// Starts an agent on the Mac from the phone: pick a worktree (or a new one
/// in a project), pick an agent profile, type the first message, send. The
/// Mac creates the worktree when asked and launches the agent with the
/// message as its prompt, in a background tab so the person at the Mac is
/// not pulled away.
@Reducer
struct ComposerFeature {
  @ObservableState
  struct State: Equatable {
    /// Enabled profiles from `agent.listProfiles`, in the Mac's order.
    var profiles: [IPC.AgentProfileSummary] = []
    var profileID: UUID?
    var target: Target?
    var prompt = ""
    /// Branch for `.newWorktree`; empty means "derive from the prompt".
    var branch = ""
    var isSending = false
    var errorMessage: String?
    /// Where the last launch landed, for the scene that sent it to
    /// navigate to.
    var lastLaunch: Launch?

    var profile: IPC.AgentProfileSummary? {
      profiles.first { $0.id == profileID } ?? profiles.first
    }

    var trimmedPrompt: String {
      prompt.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var canSend: Bool {
      !isSending && target != nil && profile != nil
    }

    /// The branch a new worktree gets: the typed one, else a slug of the
    /// prompt's first words under `agent/`, else (a prompt with no ASCII
    /// words, or none) a timestamp.
    func resolvedBranch(now: Date) -> String {
      let typed = branch.trimmingCharacters(in: .whitespacesAndNewlines)
      if !typed.isEmpty { return typed }
      let slug = ComposerFeature.slug(trimmedPrompt)
      return "agent/" + (slug.isEmpty ? ComposerFeature.stamp(now) : slug)
    }
  }

  enum Target: Equatable, Hashable {
    case worktree(projectID: String, worktreeID: String)
    case newWorktree(projectID: String)

    var projectID: String {
      switch self {
      case .worktree(let projectID, _), .newWorktree(let projectID): return projectID
      }
    }
  }

  /// Where a send lands: an existing worktree, or one to create first.
  private enum Destination: Sendable {
    case existing(worktreeID: String)
    case create(projectID: String, branch: String)
  }

  struct Launch: Equatable {
    let worktreeID: String
    let paneID: String?
  }

  enum Action: BindableAction, Equatable {
    case binding(BindingAction<State>)
    case loadProfiles
    case profilesLoaded([IPC.AgentProfileSummary])
    case profilesFailed(RemoteFailure)
    case profileSelected(UUID)
    case targetSelected(Target)
    case sendTapped
    case launched(Launch)
    case sendFailed(RemoteFailure)
    case reset
  }

  @Dependency(\.remoteClient) var remoteClient
  @Dependency(\.date.now) var now

  var body: some Reducer<State, Action> {
    BindingReducer()
    Reduce { state, action in
      switch action {
      case .binding:
        state.errorMessage = nil
        return .none

      case .loadProfiles:
        let list = remoteClient.listProfiles
        return .run { send in
          await send(.profilesLoaded(try await list()))
        } catch: { error, send in
          await send(.profilesFailed(RemoteFailure(error)))
        }

      case .profilesLoaded(let profiles):
        state.profiles = profiles.filter { $0.isEnabled && $0.isInstalled != false }
        if let id = state.profileID, !state.profiles.contains(where: { $0.id == id }) {
          state.profileID = nil
        }
        return .none

      case .profilesFailed(let failure):
        state.errorMessage = failure.message
        return .none

      case .profileSelected(let id):
        state.profileID = id
        return .none

      case .targetSelected(let target):
        state.target = target
        state.errorMessage = nil
        return .none

      case .sendTapped:
        guard state.canSend, let target = state.target, let profile = state.profile else { return .none }
        state.isSending = true
        state.errorMessage = nil
        // An agent that cannot take a kickoff prompt starts bare.
        let prompt = profile.supportsPrompt && !state.trimmedPrompt.isEmpty ? state.trimmedPrompt : nil
        // Resolved here, not in the effect: the branch name reads the clock
        // only when a worktree is actually created.
        let destination: Destination
        switch target {
        case .worktree(_, let id):
          destination = .existing(worktreeID: id)
        case .newWorktree(let projectID):
          destination = .create(projectID: projectID, branch: state.resolvedBranch(now: now))
        }
        let remote = remoteClient
        return .run { send in
          let worktreeID: String
          switch destination {
          case .existing(let id):
            worktreeID = id
          case .create(let projectID, let branch):
            worktreeID = try await remote.createWorktree(projectID, branch)
          }
          let paneID = try await remote.launchAgent(target.projectID, worktreeID, profile.id.uuidString, prompt)
          await send(.launched(Launch(worktreeID: worktreeID, paneID: paneID)))
        } catch: { error, send in
          await send(.sendFailed(RemoteFailure(error)))
        }

      case .launched(let launch):
        state.isSending = false
        state.prompt = ""
        state.branch = ""
        state.lastLaunch = launch
        // The new worktree is the natural target for a follow-up.
        if case .newWorktree(let projectID) = state.target {
          state.target = .worktree(projectID: projectID, worktreeID: launch.worktreeID)
        }
        return .none

      case .sendFailed(let failure):
        state.isSending = false
        state.errorMessage = failure.message
        return .none

      case .reset:
        state = State()
        return .none
      }
    }
  }

  /// Lowercase ASCII words of `text`, first four, joined by hyphens: a
  /// readable, valid git branch component.
  static func slug(_ text: String) -> String {
    let words = text.lowercased()
      .components(separatedBy: CharacterSet.alphanumerics.inverted)
      .filter { !$0.isEmpty && $0.allSatisfy(\.isASCII) }
    return words.prefix(4).joined(separator: "-")
  }

  /// `yyyyMMdd-HHmm` in the phone's time zone.
  static func stamp(_ date: Date) -> String {
    let c = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: date)
    return String(format: "%04d%02d%02d-%02d%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0, c.hour ?? 0, c.minute ?? 0)
  }
}

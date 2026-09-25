import CodansIPC
import ComposableArchitecture
import SwiftUI

/// The "Ask <agent>" card at the bottom of the workspace. While the field
/// is focused, the context it will send into (Mac, worktree or a new one,
/// agent) opens above it as a short list, each row a menu.
struct ComposerView: View {
  @Bindable var store: StoreOf<ComposerFeature>
  let projects: [IPC.ProjectSummary]
  let macName: String
  let onLaunched: (ComposerFeature.Launch) -> Void

  @FocusState private var isFocused: Bool

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      if isFocused {
        context
          .transition(.move(edge: .bottom).combined(with: .opacity))
      }
      card
    }
    .padding(.horizontal, 12)
    .padding(.bottom, 8)
    .animation(.snappy(duration: 0.2), value: isFocused)
  }

  // MARK: - Context rows

  private var context: some View {
    VStack(alignment: .leading, spacing: 4) {
      ContextRow(systemImage: "desktopcomputer", title: macName)
      Menu {
        worktreeMenu
      } label: {
        ContextRow(systemImage: "folder", title: targetTitle, isMenu: true)
      }
      .accessibilityIdentifier("composer-target")
      if case .newWorktree = store.target {
        HStack(spacing: 14) {
          Image(systemName: "arrow.triangle.branch")
            .frame(width: 24)
            .accessibilityHidden(true)
          TextField(branchPlaceholder, text: $store.branch)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .accessibilityIdentifier("composer-branch")
        }
        .padding(.vertical, 8)
      } else if let projectID = store.target?.projectID {
        Button {
          store.send(.targetSelected(.newWorktree(projectID: projectID)))
        } label: {
          ContextRow(systemImage: "arrow.triangle.branch", title: "Create New Worktree")
        }
        .accessibilityIdentifier("composer-new-worktree")
      }
      Menu {
        ForEach(store.profiles, id: \.id) { profile in
          Button(profile.name) { store.send(.profileSelected(profile.id)) }
        }
      } label: {
        ContextRow(systemImage: "cpu", title: store.profile?.name ?? "No agent profiles", isMenu: true)
      }
      .disabled(store.profiles.isEmpty)
      .accessibilityIdentifier("composer-profile")
    }
    .foregroundStyle(.primary)
    .padding(.horizontal, 12)
  }

  @ViewBuilder
  private var worktreeMenu: some View {
    ForEach(projects, id: \.id) { project in
      Section(project.name) {
        ForEach(project.worktrees, id: \.id) { worktree in
          Button {
            store.send(.targetSelected(.worktree(projectID: project.id, worktreeID: worktree.id)))
          } label: {
            Label(worktree.name, systemImage: "arrow.triangle.branch")
          }
        }
        Button {
          store.send(.targetSelected(.newWorktree(projectID: project.id)))
        } label: {
          Label("New Worktree", systemImage: "plus")
        }
      }
    }
  }

  // MARK: - Card

  private var card: some View {
    VStack(alignment: .leading, spacing: 10) {
      TextField(promptPlaceholder, text: $store.prompt, axis: .vertical)
        .lineLimit(1...6)
        .focused($isFocused)
        .disabled(store.profile?.supportsPrompt == false)
        .accessibilityIdentifier("composer-prompt")
      if let message = store.errorMessage {
        Text(message)
          .font(.footnote)
          .foregroundStyle(.red)
      }
      HStack(spacing: 12) {
        Menu {
          worktreeMenu
        } label: {
          Image(systemName: "plus")
            .font(.title3)
            .frame(width: 32, height: 32)
        }
        .accessibilityLabel("Choose Worktree")
        Text(targetShortTitle)
          .font(.subheadline)
          .foregroundStyle(.secondary)
          .lineLimit(1)
        Spacer(minLength: 8)
        Text(store.profile?.name ?? "")
          .font(.subheadline)
          .foregroundStyle(.secondary)
          .lineLimit(1)
        Button {
          send()
        } label: {
          Group {
            if store.isSending {
              ProgressView()
            } else {
              Image(systemName: "arrow.up")
                .font(.body.weight(.semibold))
            }
          }
          .frame(width: 36, height: 36)
          .background(store.canSend ? Color.accentColor : Color.secondary.opacity(0.25), in: .circle)
          .foregroundStyle(store.canSend ? Color.white : Color.secondary)
        }
        .disabled(!store.canSend)
        .accessibilityLabel("Start Agent")
        .accessibilityIdentifier("composer-send")
      }
    }
    .padding(14)
    .background(.regularMaterial, in: .rect(cornerRadius: 26))
    .overlay {
      RoundedRectangle(cornerRadius: 26).strokeBorder(.separator.opacity(0.5))
    }
  }

  private func send() {
    Task {
      await store.send(.sendTapped).finish()
      if let launch = store.lastLaunch, store.errorMessage == nil {
        isFocused = false
        onLaunched(launch)
      }
    }
  }

  // MARK: - Titles

  private var targetTitle: String {
    switch store.target {
    case .worktree(let projectID, let worktreeID):
      let project = projects.first { $0.id == projectID }
      let worktree = project?.worktrees.first { $0.id == worktreeID }
      return [project?.name, worktree?.name].compactMap { $0 }.joined(separator: " › ")
    case .newWorktree(let projectID):
      let name = projects.first { $0.id == projectID }?.name ?? "Project"
      return "\(name) › new worktree"
    case nil:
      return "Choose a worktree"
    }
  }

  private var targetShortTitle: String {
    switch store.target {
    case .worktree(let projectID, let worktreeID):
      return projects.first { $0.id == projectID }?.worktrees.first { $0.id == worktreeID }?.name ?? ""
    case .newWorktree:
      return "New worktree"
    case nil:
      return ""
    }
  }

  private var promptPlaceholder: String {
    guard let profile = store.profile else { return "Ask an agent" }
    return profile.supportsPrompt ? "Ask \(profile.agentName)" : "Start \(profile.agentName) (takes no message)"
  }

  private var branchPlaceholder: String {
    store.state.resolvedBranch(now: .now)
  }
}

private struct ContextRow: View {
  let systemImage: String
  let title: String
  var isMenu = false

  var body: some View {
    HStack(spacing: 14) {
      Image(systemName: systemImage)
        .frame(width: 24)
        .accessibilityHidden(true)
      Text(title)
        .lineLimit(1)
      if isMenu {
        Image(systemName: "chevron.up.chevron.down")
          .font(.caption)
          .foregroundStyle(.secondary)
          .accessibilityHidden(true)
      }
      Spacer(minLength: 0)
    }
    .font(.body)
    .padding(.vertical, 8)
    .contentShape(.rect)
  }
}

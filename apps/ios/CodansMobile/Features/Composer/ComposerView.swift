import CodansIPC
import ComposableArchitecture
import SwiftUI

/// The floating "Ask <agent>" capsule at the bottom of the home list. A tap
/// opens the full composer.
struct ComposerPill: View {
  let profile: IPC.AgentProfileSummary?
  let open: () -> Void

  var body: some View {
    Button(action: open) {
      HStack(spacing: Theme.Space.sm) {
        Image(systemName: "plus")
          .font(.system(size: 19, weight: .regular))
          .foregroundStyle(Color.ink)
          .frame(width: 24)
        Text(profile.map { "Ask \($0.agentName)" } ?? "Ask an agent")
          .font(.system(size: 17))
          .foregroundStyle(Color.inkSecondary)
          .lineLimit(1)
        Spacer(minLength: Theme.Space.xs)
        Image(systemName: "arrow.up")
          .font(.system(size: 16, weight: .semibold))
          .foregroundStyle(Color.onInk)
          .frame(width: 38, height: 38)
          .background(Color.ink, in: .circle)
      }
      .padding(.leading, 18)
      .padding(.trailing, 7)
      .frame(height: 52)
      .contentShape(.capsule)
    }
    .buttonStyle(.plain)
    .glassEffect(.regular.interactive(), in: .capsule)
    .padding(.horizontal, Theme.Space.md)
    .padding(.bottom, Theme.Space.xs)
    .accessibilityLabel(profile.map { "Ask \($0.agentName)" } ?? "Ask an agent")
    .accessibilityIdentifier("composer-pill")
  }
}

/// The full composer: where the agent will start (Mac, project, a new or
/// existing worktree, branch, agent profile) as a column of quiet context
/// rows, each a menu, over the message card with its ink send button.
struct ComposerSheet: View {
  @Bindable var store: StoreOf<ComposerFeature>
  let projects: [IPC.ProjectSummary]
  let macName: String
  let onLaunched: (ComposerFeature.Launch) -> Void

  @Environment(\.dismiss) private var dismiss
  @FocusState private var isFocused: Bool

  var body: some View {
    VStack(spacing: 0) {
      HStack {
        Button {
          dismiss()
        } label: {
          Image(systemName: "chevron.down")
            .font(.system(size: 17, weight: .semibold))
            .foregroundStyle(Color.ink)
            .frame(width: 44, height: 44)
        }
        .buttonStyle(.plain)
        .glassEffect(.regular.interactive(), in: .circle)
        .accessibilityLabel("Close")
        .accessibilityIdentifier("composer-close")
        Spacer()
      }
      .padding(.horizontal, Theme.Space.md)
      .padding(.top, Theme.Space.xs)

      Spacer(minLength: Theme.Space.md)

      context
        .padding(.horizontal, Theme.Space.lg)
        .padding(.bottom, Theme.Space.md)

      card
        .padding(.horizontal, Theme.Space.sm)
        .padding(.bottom, Theme.Space.xs)
    }
    .background(Color.surface)
    .onAppear { isFocused = true }
  }

  // MARK: - Context rows

  private var project: IPC.ProjectSummary? {
    guard let id = store.target?.projectID else { return nil }
    return projects.first { $0.id == id }
  }

  private var worktree: IPC.WorktreeSummary? {
    guard case .worktree(_, let id) = store.target else { return nil }
    return project?.worktrees.first { $0.id == id }
  }

  private var isNewWorktree: Bool {
    if case .newWorktree = store.target { return true }
    return false
  }

  private var context: some View {
    VStack(alignment: .leading, spacing: 0) {
      ContextRow(symbol: "laptopcomputer", title: macName)

      Menu {
        ForEach(projects, id: \.id) { project in
          Button(project.name) { select(project) }
        }
      } label: {
        ContextRow(symbol: "folder", title: project?.name ?? "Choose a project", isMenu: true)
      }
      .accessibilityIdentifier("composer-project")

      Menu {
        if let project {
          Button {
            store.send(.targetSelected(.newWorktree(projectID: project.id)))
          } label: {
            Label("New Worktree", systemImage: "plus")
          }
          .accessibilityIdentifier("composer-new-worktree")
          Section("Worktrees") {
            ForEach(project.worktrees, id: \.id) { worktree in
              Button(worktree.name) {
                store.send(.targetSelected(.worktree(projectID: project.id, worktreeID: worktree.id)))
              }
            }
          }
        }
      } label: {
        ContextRow(
          symbol: "square.on.square.dashed",
          title: isNewWorktree ? "New worktree" : worktree?.name ?? "Choose a worktree",
          isMenu: true)
      }
      .disabled(project == nil)
      .accessibilityIdentifier("composer-target")

      if isNewWorktree {
        HStack(spacing: 14) {
          ContextGlyph(symbol: "arrow.triangle.branch")
          TextField(store.state.resolvedBranch(now: .now), text: $store.branch)
            .font(.system(size: 17))
            .foregroundStyle(Color.ink)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .accessibilityLabel("Branch")
            .accessibilityIdentifier("composer-branch")
        }
        .frame(minHeight: 48)
      } else if let branch = worktree?.branch, branch != worktree?.name {
        // Most worktrees are named after their branch; repeating it adds
        // a row that says nothing.
        ContextRow(symbol: "arrow.triangle.branch", title: branch)
      }

      Menu {
        ForEach(store.profiles, id: \.id) { profile in
          Button {
            store.send(.profileSelected(profile.id))
          } label: {
            if profile.id == store.profile?.id {
              Label(profile.name, systemImage: "checkmark")
            } else {
              Text(profile.name)
            }
          }
        }
      } label: {
        ContextRow(symbol: "sparkles", title: store.profile?.name ?? "No agent profiles", isMenu: true)
      }
      .disabled(store.profiles.isEmpty)
      .accessibilityIdentifier("composer-profile")
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }

  /// Switching project keeps the kind of target: a new worktree stays a new
  /// worktree, an existing one lands on the project's own selection.
  private func select(_ project: IPC.ProjectSummary) {
    if isNewWorktree || project.worktrees.isEmpty {
      store.send(.targetSelected(.newWorktree(projectID: project.id)))
      return
    }
    let worktree = project.worktrees.first { $0.id == project.selectedWorktreeID } ?? project.worktrees[0]
    store.send(.targetSelected(.worktree(projectID: project.id, worktreeID: worktree.id)))
  }

  // MARK: - Card

  private var card: some View {
    VStack(alignment: .leading, spacing: Theme.Space.sm) {
      TextField(promptPlaceholder, text: $store.prompt, axis: .vertical)
        .font(.system(size: 17))
        .lineLimit(1...8)
        .focused($isFocused)
        .disabled(store.profile?.supportsPrompt == false)
        .accessibilityIdentifier("composer-prompt")
      if let message = store.errorMessage {
        Label(message, systemImage: "exclamationmark.circle")
          .font(.system(size: 13))
          .foregroundStyle(Color.failure)
          .accessibilityIdentifier("composer-error")
      } else if !store.isConnectionLive {
        Text("Waiting for \(macName) to connect…")
          .font(.system(size: 13))
          .foregroundStyle(Color.inkSecondary)
      }
      HStack(spacing: Theme.Space.sm) {
        Menu {
          ForEach(projects, id: \.id) { project in
            Section(project.name) {
              ForEach(project.worktrees, id: \.id) { worktree in
                Button(worktree.name) {
                  store.send(.targetSelected(.worktree(projectID: project.id, worktreeID: worktree.id)))
                }
              }
              Button("New Worktree", systemImage: "plus") {
                store.send(.targetSelected(.newWorktree(projectID: project.id)))
              }
            }
          }
        } label: {
          Image(systemName: "plus")
            .font(.system(size: 20, weight: .regular))
            .foregroundStyle(Color.ink)
            .frame(width: 36, height: 36)
            .contentShape(.rect)
        }
        .accessibilityLabel("Choose Worktree")
        Spacer(minLength: Theme.Space.xs)
        PrimaryCircleButton(isEnabled: store.canSend, isBusy: store.isSending, size: 40, action: send)
          .accessibilityLabel("Start Agent")
          .accessibilityIdentifier("composer-send")
      }
    }
    .padding(.horizontal, Theme.Space.md)
    .padding(.top, 14)
    .padding(.bottom, 10)
    .background(Color.surfaceElevated, in: .rect(cornerRadius: Theme.Radius.panel, style: .continuous))
    .overlay {
      RoundedRectangle(cornerRadius: Theme.Radius.panel, style: .continuous).strokeBorder(Color.hairline)
    }
    .shadow(color: .black.opacity(0.06), radius: 16, y: 4)
  }

  private func send() {
    Task {
      await store.send(.sendTapped).finish()
      // `sendTapped` cleared any earlier result, so this is this send's.
      if let launch = store.lastLaunch {
        store.send(.launchHandled)
        isFocused = false
        onLaunched(launch)
      }
    }
  }

  private var promptPlaceholder: String {
    guard let profile = store.profile else { return "Ask an agent" }
    return profile.supportsPrompt ? "Ask \(profile.agentName)" : "Start \(profile.agentName) (takes no message)"
  }
}

private struct ContextGlyph: View {
  let symbol: String

  var body: some View {
    Image(systemName: symbol)
      .font(.system(size: 18, weight: .regular))
      .foregroundStyle(Color.inkSecondary)
      .frame(width: 26)
      .accessibilityHidden(true)
  }
}

private struct ContextRow: View {
  let symbol: String
  let title: String
  var isMenu = false

  var body: some View {
    HStack(spacing: 14) {
      ContextGlyph(symbol: symbol)
      Text(title)
        .font(.system(size: 17))
        .foregroundStyle(Color.ink)
        .lineLimit(1)
      if isMenu {
        Image(systemName: "chevron.up.chevron.down")
          .font(.system(size: 12, weight: .medium))
          .foregroundStyle(Color.inkTertiary)
          .accessibilityHidden(true)
      }
      Spacer(minLength: 0)
    }
    .frame(minHeight: 48)
    .contentShape(.rect)
  }
}

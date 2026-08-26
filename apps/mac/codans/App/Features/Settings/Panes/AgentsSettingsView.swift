import CodansCore
import SwiftUI

/// Settings → Agents. Two screens behind one sidebar row: the profile list,
/// and the per-profile detail editor.
///
/// Navigation is a local `@State` swap rather than a nested `NavigationStack`
/// on purpose — this pane lives in the detail column of the Settings window's
/// `NavigationSplitView`, and a nested stack would fight the window for the
/// `navigationTitle` binding. The back button below restores the list.
///
/// Reads come from `@Environment(SettingsStore.self)` so an edit in the
/// detail screen reflects in the list without a manual refresh; writes go
/// through `mutateAgents`, the single writer for the `agents` subtree.
struct AgentsSettingsView: View {
  @Environment(SettingsStore.self) private var settingsStore
  /// Which agent CLIs are actually on disk. App-scoped so this pane and the
  /// worktree toolbar's Agents menu never disagree about what is runnable.
  @Environment(AgentInstallationStore.self) private var installation
  /// Non-nil = the detail screen for that profile is showing.
  @State private var editingProfileID: UUID?

  private var profiles: [AgentProfile] {
    settingsStore.settings.agents.profiles
  }

  var body: some View {
    Group {
      if let editingProfileID, let profile = profiles.first(where: { $0.id == editingProfileID }) {
        AgentProfileDetailView(
          profile: profile,
          isInstalled: installation.isInstalled(profile.kind),
          onChange: update,
          onRemove: { remove(id: profile.id) },
          onBack: { self.editingProfileID = nil }
        )
      } else {
        list
      }
    }
    .task {
      await installation.scanIfNeeded()
    }
  }

  // MARK: - List

  private var list: some View {
    Form {
      Section {
        ForEach(profiles) { profile in
          row(for: profile)
        }
        addRow
      } header: {
        Text("Agent Profiles")
      } footer: {
        Text(
          "Named launch presets for the agents installed on this Mac, available from the "
            + "worktree toolbar's Agents menu. Profiles for an agent codans cannot find on "
            + "your PATH are shown greyed out."
        )
      }
    }
    .formStyle(.grouped)
  }

  /// One profile row: enable checkbox, brand glyph, name, the agent it
  /// launches, and a chevron into the detail screen. An agent that is not
  /// installed renders the whole row secondary and blocks the checkbox — the
  /// profile stays editable (tap through to the detail screen) but cannot be
  /// armed for a launch that would only produce "command not found".
  ///
  /// The checkbox is a sibling of — not nested inside — the navigating
  /// Button: a `LabeledContent` row with an `onTapGesture` does not reliably
  /// pick up clicks inside a grouped `Form`, and nesting the Toggle in the
  /// Button would make it uncheckable.
  @ViewBuilder
  private func row(for profile: AgentProfile) -> some View {
    let installed = installation.isInstalled(profile.kind)
    HStack(spacing: 8) {
      Toggle(
        isOn: Binding(
          get: { profile.isEnabled && installed },
          set: { newValue in
            var updated = profile
            updated.isEnabled = newValue
            update(updated)
          }
        )
      ) {
        EmptyView()
      }
      .labelsHidden()
      .toggleStyle(.checkbox)
      .disabled(!installed)
      .accessibilityLabel("Enable \(profile.displayName)")

      Button {
        editingProfileID = profile.id
      } label: {
        HStack(spacing: 8) {
          AgentLogoView(kind: profile.kind, size: 16, tint: installed ? .primary : .tertiary)
          Text(profile.displayName)
            .lineLimit(1)
          Spacer(minLength: 12)
          Text(profile.descriptor.displayName)
            .foregroundStyle(.secondary)
            .lineLimit(1)
          Image(systemName: "chevron.right")
            .font(.caption.weight(.semibold))
            .foregroundStyle(.tertiary)
            .accessibilityHidden(true)
        }
        .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      .accessibilityHint(installed ? "Edit profile" : "Agent not installed — edit profile")
    }
    .foregroundStyle(installed ? .primary : .secondary)
  }

  /// Trailing action row. The plain half adds a profile for the first agent
  /// with no profile yet (or Claude Code when every agent already has one);
  /// the caret half picks the agent explicitly. Mirrors the Commands pane's
  /// add affordance.
  private var addRow: some View {
    HStack(spacing: 4) {
      Button {
        add(kind: suggestedKindForAdd)
      } label: {
        Label("Add Profile", systemImage: "plus")
      }
      .buttonStyle(.borderless)

      Menu {
        ForEach(AgentKind.allCases, id: \.self) { kind in
          Button {
            add(kind: kind)
          } label: {
            Label {
              Text(AgentCatalog.descriptor(for: kind).displayName)
            } icon: {
              // The Label's Text already announces the agent; letting
              // VoiceOver read the glyph too would double-speak it.
              AgentMenuIcon.image(for: kind)
                .accessibilityHidden(true)
            }
          }
        }
      } label: {
        Image(systemName: "chevron.down")
          .font(.caption.weight(.semibold))
          .frame(width: 16, height: 16)
          .contentShape(Rectangle())
          .accessibilityLabel("Add profile for a specific agent")
      }
      .menuStyle(.borderlessButton)
      .menuIndicator(.hidden)
      .fixedSize()
      .help("Add a profile for a specific agent")
    }
  }

  /// The agent an unqualified "Add Profile" creates: the first built-in with
  /// no profile yet, so repeated taps walk the catalogue instead of stacking
  /// duplicates of one agent.
  private var suggestedKindForAdd: AgentKind {
    let configured = Set(profiles.map(\.kind))
    return AgentProfile.seededKinds.first { !configured.contains($0) } ?? .claudeCode
  }

  // MARK: - Mutations

  private func update(_ profile: AgentProfile) {
    settingsStore.mutateAgents { agents in
      guard let index = agents.profiles.firstIndex(where: { $0.id == profile.id }) else { return }
      agents.profiles[index] = profile
    }
  }

  private func add(kind: AgentKind) {
    // A second profile for the same agent needs a distinct id, so only the
    // first one claims the deterministic seed id.
    let takenIDs = Set(profiles.map(\.id))
    let seedID = AgentProfile.seedID(for: kind)
    let new = AgentProfile(
      id: takenIDs.contains(seedID) ? UUID() : seedID,
      kind: kind
    )
    settingsStore.mutateAgents { $0.profiles.append(new) }
    editingProfileID = new.id
  }

  private func remove(id: UUID) {
    settingsStore.mutateAgents { $0.profiles.removeAll { $0.id == id } }
    editingProfileID = nil
  }
}

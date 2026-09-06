import CodansCore
import ComposableArchitecture
import SwiftUI

/// Native toolbar split button that starts a coding agent in the selected
/// Worktree. Sits immediately left of the Run split button: both halves of
/// the toolbar's action cluster are "start something here", with agents first
/// because that is the more frequent entry point for this app's audience.
///
/// Primary action launches the first offered `AgentProfile`; the chevron half
/// lists every offered profile plus a "Manage Agents…" footer. "Offered" is
/// the enabled profiles minus those whose CLI the shell could not resolve —
/// see `AgentInstallationStore.offeredProfiles` for why that filter fails
/// open. Empty-state:
/// both halves route to the Agents settings pane so a user with no configured
/// profile lands where they can make one.
///
/// Hand off is deliberately absent: it acts on the agent in one pane, and the
/// pane's own info menu resolves that source directly instead of going
/// through the header's focused-pane guess.
///
/// Both halves dispatch through `WorktreeHeaderFeature.delegate` so
/// `RootFeature` owns the `HierarchyClient.launchAgentProfile` effect and
/// resolves the target Worktree at handle-time.
struct HeaderAgentSplitButton: View {
  @Bindable var store: StoreOf<WorktreeHeaderFeature>
  @Environment(SettingsStore.self) private var settingsStore
  @Environment(AgentInstallationStore.self) private var installation

  var body: some View {
    // Read the profiles once, here, inside body — Observation only tracks
    // reads that happen during a body re-evaluation, and the array doubles as
    // the Menu's `.id(_:)` identity so a Settings-side edit rebuilds the
    // cached NSMenu instead of serving stale items. Same rationale as
    // `HeaderRunScriptSplitButton`.
    let profiles = AgentInstallationStore.offeredProfiles(
      enabled: settingsStore.settings.agents.enabledProfiles,
      isInstalled: installation.isInstalled
    )
    let primary = profiles.first
    let primaryName = primary?.displayName ?? "Agents"

    Menu {
      caretMenu(profiles: profiles)
    } label: {
      // Manual HStack for the same reason as the Run button: the toolbar's
      // default LabelStyle collapses `Label(_:systemImage:)` in ways that
      // fight a custom leading glyph.
      HStack(spacing: 6) {
        if let primary {
          AgentLogoView(icon: primary.icon, size: 16, tint: .primary)
        } else {
          Image(systemName: "sparkles")
            .frame(width: 16, height: 16)
            .accessibilityHidden(true)
        }
        Text(primaryName).lineLimit(1)
      }
    } primaryAction: {
      if let primary {
        store.send(.launchAgentTapped(profileID: primary.id))
      } else {
        store.send(.manageAgentsTapped)
      }
    }
    .menuIndicator(.visible)
    .accessibilityLabel(primary == nil ? "Manage agents" : "Start \(primaryName)")
    .help(primary == nil ? "Manage Agents…" : "Start \(primaryName)")
    .id(Self.identitySignature(of: profiles))
  }

  // MARK: - Caret menu

  @ViewBuilder
  private func caretMenu(profiles: [AgentProfile]) -> some View {
    if !profiles.isEmpty {
      ForEach(profiles) { profile in
        Button {
          store.send(.launchAgentTapped(profileID: profile.id))
        } label: {
          Label {
            Text(profile.displayName)
          } icon: {
            // The Label's Text already announces the profile; letting
            // VoiceOver read the glyph too would double-speak it.
            AgentMenuIcon.image(for: profile.icon)
              .accessibilityHidden(true)
          }
        }
      }
      Divider()
    }
    Button("Manage Agents…") {
      store.send(.manageAgentsTapped)
    }
  }

  /// Stable identity for `.id(_:)`. Folds every field the menu renders plus
  /// the list's order, so a rename / reorder / enable-toggle in Settings
  /// invalidates the cached NSMenu.
  private static func identitySignature(of profiles: [AgentProfile]) -> String {
    profiles
      .map { "\($0.id)|\($0.displayName)|\($0.kind.rawValue)|\($0.systemImage ?? "")" }
      .joined(separator: "·")
  }
}

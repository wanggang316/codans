import CodansCore
import ComposableArchitecture
import SwiftUI

/// Native toolbar split button that starts a coding agent in the selected
/// Worktree. Sits immediately left of the Run split button: both halves of
/// the toolbar's action cluster are "start something here", with agents first
/// because that is the more frequent entry point for this app's audience.
///
/// Primary action launches the first enabled `AgentProfile`; the chevron half
/// leads with "Hand Off…" (pass the focused pane's task to another agent),
/// then lists every enabled profile plus a "Manage Agents…" footer. Empty-state:
/// both halves route to the Agents settings pane so a user with no configured
/// profile lands where they can make one.
///
/// Both halves dispatch through `WorktreeHeaderFeature.delegate` so
/// `RootFeature` owns the `HierarchyClient.launchAgentProfile` effect and
/// resolves the target Worktree at handle-time.
struct HeaderAgentSplitButton: View {
  @Bindable var store: StoreOf<WorktreeHeaderFeature>
  @Environment(SettingsStore.self) private var settingsStore

  var body: some View {
    // Read the profiles once, here, inside body — Observation only tracks
    // reads that happen during a body re-evaluation, and the array doubles as
    // the Menu's `.id(_:)` identity so a Settings-side edit rebuilds the
    // cached NSMenu instead of serving stale items. Same rationale as
    // `HeaderRunScriptSplitButton`.
    let profiles = settingsStore.settings.agents.enabledProfiles
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
    // Leads the menu: the source is whatever agent runs in the focused
    // pane, so the row is always offered and RootFeature explains (via a
    // status toast) when there is no agent to ask.
    Button {
      store.send(.handOffTapped)
    } label: {
      Label("Hand Off…", systemImage: "arrow.right.arrow.left")
    }
    Divider()
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

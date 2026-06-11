import AppKit
import ComposableArchitecture
import SwiftUI
import CodansCore

/// GitHub section of the Settings window. Three blocks:
///   - Availability: banner driven by a local `GitHubAvailability` state, probed on
///     appear and on an explicit Re-check tap via the `GitHubClient` dependency.
///   - Defaults: global merge strategy + post-merge Worktree action pickers, written
///     through `SettingsStore.mutateGeneral`.
///   - Per-Project overrides: deferred to a follow-up commit — `RepositorySettings`
///     already carries the fields; only the UI wiring remains.
///
/// Settings window is a separate scene from the main window with its own TCA store, so
/// this view holds its own availability state rather than sharing RootFeature's
/// `GitHubFeature` store. A future refactor can consolidate the two once a shared
/// app-level store emerges.
struct GitHubSettingsView: View {
  let settingsStore: SettingsStore

  @Dependency(GitHubClient.self) private var gitHub
  @State private var availability: GitHubAvailability = .unknown
  @State private var isChecking: Bool = false

  var body: some View {
    Form {
      Section("Availability") {
        availabilityRow
        HStack {
          Button("Re-check") {
            Task { await probe() }
          }
          .disabled(isChecking)
          Button("Open gh docs") {
            if let url = URL(string: "https://cli.github.com/manual/") {
              NSWorkspace.shared.open(url)
            }
          }
        }
      }

      Section("Defaults") {
        Picker("Default merge strategy", selection: mergeStrategyBinding) {
          Text("Use gh default").tag(Optional<MergeStrategy>.none)
          ForEach(MergeStrategy.allCases, id: \.self) { strategy in
            Text(strategy.displayName).tag(Optional(strategy))
          }
        }

        Picker("After merging a PR", selection: postMergeActionBinding) {
          Text("Ask each time").tag(Optional<MergedWorktreeAction>.none)
          ForEach(MergedWorktreeAction.allCases.filter { $0 != .ask }, id: \.self) { action in
            Text(action.displayName).tag(Optional(action))
          }
        }
      }

      Section("Per-Project overrides") {
        Text(
          "Per-Project merge strategy and post-merge action overrides land in a follow-up "
            + "commit. The global defaults above apply everywhere for now."
        )
        .font(.callout)
        .foregroundStyle(.secondary)
      }
    }
    .formStyle(.grouped)
    .task {
      await probe()
    }
  }

  @ViewBuilder
  private var availabilityRow: some View {
    switch availability {
    case .available(let host, let user):
      HStack {
        Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        Text("Connected to \(host) as @\(user)")
      }
    case .unavailable(let reason):
      HStack(alignment: .top) {
        Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.yellow)
        VStack(alignment: .leading, spacing: 4) {
          Text(reason)
            .multilineTextAlignment(.leading)
          if reason.contains("brew install gh") {
            Button("Copy `brew install gh`") {
              NSPasteboard.general.clearContents()
              NSPasteboard.general.setString("brew install gh", forType: .string)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
          }
        }
      }
    case .unknown:
      HStack {
        ProgressView().controlSize(.small)
        Text("Checking GitHub CLI availability…")
      }
    }
  }

  private func probe() async {
    isChecking = true
    let result = await gitHub.availability()
    availability = result
    isChecking = false
  }

  // MARK: - Bindings

  private var mergeStrategyBinding: Binding<MergeStrategy?> {
    Binding(
      get: { settingsStore.settings.general.defaultMergeStrategy },
      set: { newValue in
        settingsStore.mutateGeneral { $0.defaultMergeStrategy = newValue }
      }
    )
  }

  private var postMergeActionBinding: Binding<MergedWorktreeAction?> {
    Binding(
      get: { settingsStore.settings.general.postMergeAction },
      set: { newValue in
        settingsStore.mutateGeneral { $0.postMergeAction = newValue }
      }
    )
  }
}

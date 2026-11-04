import AppKit
import CodansCore
import ComposableArchitecture
import SwiftUI

/// "Code Hosts" section of the Settings window (ADR 0004 item 10):
///   - One block per Code Host: the availability of its CLI (`gh`, `glab`), the host and
///     user it is logged in as, Re-check, and a docs link. Probed on appear and on
///     Re-check through the `CodeHostClient` dependency.
///   - Defaults that apply to every Code Host: merge strategy and post-merge Worktree
///     action, written through `SettingsStore.mutateGeneral`.
///
/// A Code Host serves repositories; the "Hosts" pane lists machines (ADR 0003). The pane
/// text names both so the two are not confused.
///
/// The Settings window is a separate scene with its own TCA store, so this view keeps its
/// own availability state instead of sharing RootFeature's `CodeHostFeature` store.
struct CodeHostsSettingsView: View {
  let settingsStore: SettingsStore

  @Dependency(CodeHostClient.self) private var codeHost
  @State private var availability: [CodeHostKind: CodeHostAvailability] = [:]
  @State private var checking: Set<CodeHostKind> = []

  var body: some View {
    Form {
      Section {
        Text(
          "codans reads pull requests and merge requests through the CLI of each Code Host. "
            + "A Project uses the Code Host of its origin remote; set it in the Project settings "
            + "when neither CLI knows the host. Machines that run Projects are in Hosts."
        )
        .font(.callout)
        .foregroundStyle(.secondary)
      }

      ForEach(CodeHostKind.allCases, id: \.self) { kind in
        Section(kind.displayName) {
          availabilityRow(kind)
          HStack {
            Button("Re-check") {
              Task {
                await codeHost.invalidateResolution()
                await probe(kind)
              }
            }
            .disabled(checking.contains(kind))
            Button("Open \(kind.cliName) docs") {
              if let url = Self.docsURL(kind) {
                NSWorkspace.shared.open(url)
              }
            }
          }
        }
      }

      Section {
        Picker("Default merge strategy", selection: mergeStrategyBinding) {
          Text("Default (\(MergeStrategy.squash.displayName))").tag(MergeStrategy?.none)
          ForEach(MergeStrategy.allCases, id: \.self) { strategy in
            Text(strategy.displayName).tag(Optional(strategy))
          }
        }

        Picker("After merging", selection: postMergeActionBinding) {
          Text("Ask each time").tag(MergedWorktreeAction?.none)
          ForEach(MergedWorktreeAction.allCases.filter { $0 != .ask }, id: \.self) { action in
            Text(action.displayName).tag(Optional(action))
          }
        }
      } header: {
        Text("Defaults")
      } footer: {
        Text(
          "These apply to GitHub and GitLab. On GitLab, the project's merge method applies, "
            + "and \(MergeStrategy.rebase.displayName) uses Merge."
        )
        .font(.footnote)
        .foregroundStyle(.secondary)
      }
    }
    .formStyle(.grouped)
    .task {
      await withTaskGroup(of: Void.self) { group in
        for kind in CodeHostKind.allCases {
          group.addTask { await probe(kind) }
        }
      }
    }
  }

  static func docsURL(_ kind: CodeHostKind) -> URL? {
    switch kind {
    case .github: return URL(string: "https://cli.github.com/manual/")
    case .gitlab: return URL(string: "https://docs.gitlab.com/cli/")
    }
  }

  @ViewBuilder
  private func availabilityRow(_ kind: CodeHostKind) -> some View {
    switch availability[kind] ?? .unknown {
    case .available(let host, let user):
      HStack {
        Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
          .accessibilityHidden(true)
        Text(
          user.isEmpty ? "\(kind.cliName): connected to \(host)" : "\(kind.cliName): connected to \(host) as @\(user)")
      }
    case .unavailable(let reason):
      HStack(alignment: .top) {
        Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.yellow)
          .accessibilityHidden(true)
        VStack(alignment: .leading, spacing: 4) {
          Text(reason)
            .multilineTextAlignment(.leading)
          let install = "brew install \(kind.cliName)"
          if reason.contains(install) {
            Button("Copy `\(install)`") {
              NSPasteboard.general.clearContents()
              NSPasteboard.general.setString(install, forType: .string)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
          }
        }
      }
    case .unknown:
      HStack {
        ProgressView().controlSize(.small)
        Text("Checking \(kind.cliDisplayName)…")
      }
    }
  }

  private func probe(_ kind: CodeHostKind) async {
    checking.insert(kind)
    availability[kind] = .unknown
    availability[kind] = await codeHost.availability(kind)
    checking.remove(kind)
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

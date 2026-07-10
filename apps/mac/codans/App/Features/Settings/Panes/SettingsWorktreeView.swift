import CodansCore
import SwiftUI

/// Worktree settings pane — global defaults for worktree creation, copying, and
/// cleanup. These apply across all projects unless overridden per-project.
struct SettingsWorktreeView: View {
  let settingsStore: SettingsStore

  var body: some View {
    Form {
      Section("Creation") {
        LabeledContent("Default directory") {
          HStack(spacing: 6) {
            Text(
              settingsStore.settings.worktree
                .resolveGlobalBaseDirectory()
                .path(percentEncoded: false)
            )
            .foregroundStyle(
              settingsStore.settings.worktree.defaultWorktreesDirectory == nil
                ? .secondary
                : .primary
            )
            .textSelection(.enabled)
            .lineLimit(1)
            .truncationMode(.middle)
            .frame(maxWidth: .infinity, alignment: .trailing)
            Button {
              chooseWorktreeDirectory()
            } label: {
              Image(systemName: "folder")
            }
            .buttonStyle(.borderless)
            .help("Choose a different directory…")
            if settingsStore.settings.worktree.defaultWorktreesDirectory != nil {
              Button {
                settingsStore.mutateWorktree { $0.defaultWorktreesDirectory = nil }
              } label: {
                Image(systemName: "arrow.uturn.backward")
                  .accessibilityHidden(true)
              }
              .buttonStyle(.borderless)
              .help("Reset to default")
              .accessibilityLabel("Reset to default")
            }
          }
        }

        Toggle(
          "Fetch remote before creating worktree",
          isOn: fetchRemoteBinding
        )

        Toggle(
          "Switch to the new worktree when it's ready",
          isOn: autoSwitchToNewWorktreeBinding
        )
      }

      Section {
        Toggle(
          "Copy .gitignore-listed files",
          isOn: copyIgnoredBinding
        )
        Toggle(
          "Copy untracked files",
          isOn: copyUntrackedBinding
        )
      } header: {
        Text("Copy on creation")
      } footer: {
        Text(
          "Files matching the above criteria in the main worktree are copied when "
            + "creating a new worktree."
        )
      }

      Section {
        Toggle(
          "Auto-delete archived worktrees",
          isOn: autoDeleteBinding
        )

        if settingsStore.settings.worktree.autoDeleteArchived {
          Picker(
            "Delete after",
            selection: autoDeletePeriodBinding
          ) {
            ForEach(AutoDeletePeriod.allCases, id: \.self) { period in
              Text(period.label).tag(period)
            }
          }
        }

        Toggle(
          "Delete remote branch with worktree",
          isOn: deleteRemoteBranchBinding
        )
      } header: {
        Text("Cleanup")
      }
    }
    .formStyle(.grouped)
  }

  private func chooseWorktreeDirectory() {
    let panel = NSOpenPanel()
    panel.allowsMultipleSelection = false
    panel.canChooseFiles = false
    panel.canChooseDirectories = true
    panel.prompt = "Choose"

    let response = panel.runModal()
    guard response == .OK, let url = panel.url else { return }
    settingsStore.mutateWorktree { $0.defaultWorktreesDirectory = url.path }
  }

  // MARK: - Bindings

  private var fetchRemoteBinding: Binding<Bool> {
    Binding(
      get: { settingsStore.settings.worktree.fetchRemoteOnCreate },
      set: { newValue in
        settingsStore.mutateWorktree { $0.fetchRemoteOnCreate = newValue }
      }
    )
  }

  private var autoSwitchToNewWorktreeBinding: Binding<Bool> {
    Binding(
      get: { settingsStore.settings.worktree.autoSwitchToNewWorktree },
      set: { newValue in
        settingsStore.mutateWorktree { $0.autoSwitchToNewWorktree = newValue }
      }
    )
  }

  private var copyIgnoredBinding: Binding<Bool> {
    Binding(
      get: { settingsStore.settings.worktree.copyIgnoredOnCreate },
      set: { newValue in
        settingsStore.mutateWorktree { $0.copyIgnoredOnCreate = newValue }
      }
    )
  }

  private var copyUntrackedBinding: Binding<Bool> {
    Binding(
      get: { settingsStore.settings.worktree.copyUntrackedOnCreate },
      set: { newValue in
        settingsStore.mutateWorktree { $0.copyUntrackedOnCreate = newValue }
      }
    )
  }

  private var autoDeleteBinding: Binding<Bool> {
    Binding(
      get: { settingsStore.settings.worktree.autoDeleteArchived },
      set: { newValue in
        settingsStore.mutateWorktree { $0.autoDeleteArchived = newValue }
      }
    )
  }

  private var autoDeletePeriodBinding: Binding<AutoDeletePeriod> {
    Binding(
      get: { settingsStore.settings.worktree.autoDeletePeriod },
      set: { newValue in
        settingsStore.mutateWorktree { $0.autoDeletePeriod = newValue }
      }
    )
  }

  private var deleteRemoteBranchBinding: Binding<Bool> {
    Binding(
      get: { settingsStore.settings.worktree.deleteRemoteBranchWithWorktree },
      set: { newValue in
        settingsStore.mutateWorktree { $0.deleteRemoteBranchWithWorktree = newValue }
      }
    )
  }
}

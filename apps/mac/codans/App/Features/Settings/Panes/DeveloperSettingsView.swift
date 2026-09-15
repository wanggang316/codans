import CodansCore
import SwiftUI

/// Developer detail pane. Three stacked sections:
/// 1. `codans` CLI status + install/uninstall via `CLIInstallStatusCard`.
/// 2. Bundled agent skills, linked per agent via `SkillInstallSection`.
/// 3. Diagnostics via `DiagnosticsSection`.
///
/// Dependencies arrive through `@Environment` so the T1-frozen detail switch
/// in `SettingsWindowView` does not need to be touched.
struct DeveloperSettingsView: View {
  @Environment(SettingsStore.self) private var settingsStore
  @Environment(DeveloperPaneDependencies.self) private var deps

  var body: some View {
    Form {
      Section("CLI") {
        CLIInstallStatusCard(installer: deps.installer, settingsStore: settingsStore)
      }
      if let skillInstaller = deps.skillInstaller {
        Section("Agent skills") {
          SkillInstallSection(model: SkillInstallModel(installer: skillInstaller))
        }
      }
      Section("Diagnostics") {
        DiagnosticsSection()
      }
    }
    .formStyle(.grouped)
  }
}

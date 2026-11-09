import CodansCore
import SwiftUI

/// Developer detail pane. Stacked sections:
/// 1. `codans` CLI status + install/uninstall via `CLIInstallStatusCard`.
/// 2. One section per bundled agent skill, linked per agent via
///    `SkillInstallSections`.
///
/// Dependencies arrive through `@Environment` so the T1-frozen detail switch
/// in `SettingsWindowView` does not need to be touched.
struct DeveloperSettingsView: View {
  @Environment(SettingsStore.self) private var settingsStore
  @Environment(DeveloperPaneDependencies.self) private var deps
  @State private var skillModel: SkillInstallModel?

  var body: some View {
    Form {
      Section("CLI") {
        CLIInstallStatusCard(installer: deps.installer, settingsStore: settingsStore)
      }
      if let skillModel {
        SkillInstallSections(model: skillModel)
      }
    }
    .formStyle(.grouped)
    .task {
      guard skillModel == nil, let skillInstaller = deps.skillInstaller else { return }
      let model = SkillInstallModel(installer: skillInstaller)
      model.refresh()
      skillModel = model
    }
  }
}

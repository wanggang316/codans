import CodansCore
import SwiftUI

/// Settings → Agents → one profile. Four grouped sections mirroring how a
/// launch is composed: who it is (Profile), what it will type (Launch
/// Preview), the knobs its CLI exposes (Details), and the escape hatches
/// (Advanced).
///
/// The view is stateless with respect to the profile: every edit rebuilds an
/// `AgentProfile` value and hands it to `onChange`, which is the pane's single
/// write path into `SettingsStore`. Text fields write through on each
/// keystroke — `SettingsStore.scheduleSave` already trailing-debounces the
/// disk write, so a local draft would only add a commit-timing bug.
///
/// Rows for options the selected agent does not expose are omitted rather
/// than shown disabled: an agent with no model flag has no meaningful
/// "Runtime default" to display, and a dead picker reads as a bug.
struct AgentProfileDetailView: View {
  let profile: AgentProfile
  /// Drives the "not installed" banner. Sourced from the pane's shared probe
  /// so the list and this screen never disagree.
  let isInstalled: Bool
  let onChange: (AgentProfile) -> Void
  let onRemove: () -> Void
  let onBack: () -> Void

  @State private var isConfirmingRemoval = false
  @State private var isPickingIcon = false

  private var descriptor: AgentDescriptor { profile.descriptor }

  var body: some View {
    Form {
      if !isInstalled {
        Section {
          Label(
            "\(descriptor.executable) was not found on your PATH. Install the agent to launch "
              + "this profile.",
            systemImage: "exclamationmark.triangle.fill"
          )
          .foregroundStyle(.secondary)
        }
      }

      profileSection
      launchPreviewSection
      detailsSection
      advancedSection

      Section {
        Button("Remove Profile…", role: .destructive) {
          isConfirmingRemoval = true
        }
      }
    }
    .formStyle(.grouped)
    // Window-toolbar back affordance, not a row in the form: this is the
    // same place System Settings puts it, and the detail column's toolbar
    // merges into the Settings window's own.
    .toolbar {
      ToolbarItem(placement: .navigation) {
        Button(action: onBack) {
          Image(systemName: "chevron.backward")
        }
        .help("Back to Agents")
        .accessibilityLabel("Back to Agents")
      }
    }
    .confirmationDialog(
      "Remove \"\(profile.displayName)\"?",
      isPresented: $isConfirmingRemoval,
      titleVisibility: .visible
    ) {
      Button("Remove Profile", role: .destructive, action: onRemove)
      Button("Cancel", role: .cancel) {}
    } message: {
      Text("The profile disappears from the toolbar Agents menu. The agent itself is untouched.")
    }
  }

  // MARK: - Profile

  private var profileSection: some View {
    Section("Profile") {
      LabeledContent("Name") {
        // Empty prompt shows the agent's own name — the same string
        // `displayName` falls back to, so the field previews what clearing it
        // would produce.
        TextField("", text: binding(\.name), prompt: Text(descriptor.displayName))
          .textFieldStyle(.plain)
          .multilineTextAlignment(.trailing)
      }

      Picker("Agent", selection: kindBinding) {
        ForEach(AgentKind.allCases, id: \.self) { kind in
          Text(AgentCatalog.descriptor(for: kind).displayName).tag(kind)
        }
      }

      iconRow
    }
  }

  /// Icon row: current glyph, what it is, and a popover to swap it for any
  /// SF Symbol. Two profiles on the same agent are otherwise indistinguishable
  /// at a glance in the toolbar menu and the tab strip.
  private var iconRow: some View {
    LabeledContent {
      Button("Change…") { isPickingIcon = true }
        .popover(isPresented: $isPickingIcon, arrowEdge: .bottom) { iconPicker }
    } label: {
      HStack(spacing: 12) {
        AgentLogoView(icon: profile.icon, size: 22, tint: .primary)
          .frame(width: 38, height: 38)
          .background(.quaternary, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        VStack(alignment: .leading, spacing: 2) {
          Text("Icon")
          if let symbol = profile.systemImage, !symbol.isEmpty {
            Text(symbol)
              .font(.system(.callout, design: .monospaced))
              .foregroundStyle(.secondary)
          } else {
            Text(descriptor.iconSummary)
              .font(.callout)
              .foregroundStyle(.secondary)
          }
        }
      }
    }
  }

  private var iconPicker: some View {
    VStack(alignment: .leading, spacing: 10) {
      Text("Icon")
        .font(.headline)
      Text("Pick a symbol, or type any SF Symbol name your system has.")
        .font(.caption)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)

      SFSymbolPicker(selection: symbolBinding)

      Divider()

      // Clearing the override is the only way back to the brand mark — an
      // empty text field would read as "no icon" rather than "the default".
      Button {
        var updated = profile
        updated.systemImage = nil
        onChange(updated)
      } label: {
        Label("Use \(descriptor.displayName) Icon", systemImage: "arrow.uturn.backward")
      }
      .buttonStyle(.borderless)
      .disabled(profile.systemImage == nil)
    }
    .padding(12)
    .frame(width: 360)
  }

  /// Live symbol name for the picker. Reading falls back to a neutral
  /// placeholder so the grid has something to highlight before the user has
  /// overridden anything; writing an empty string clears the override.
  private var symbolBinding: Binding<String> {
    Binding(
      get: { profile.systemImage ?? "" },
      set: { newValue in
        var updated = profile
        let trimmed = newValue.trimmingCharacters(in: .whitespaces)
        updated.systemImage = trimmed.isEmpty ? nil : trimmed
        onChange(updated)
      }
    )
  }

  // MARK: - Launch preview

  private var launchPreviewSection: some View {
    Section("Launch Preview") {
      Text(
        "codans types this command into the pane it opens. Environment variables ride an "
          + "env prefix so they reach the agent only — the pane's shell keeps your normal "
          + "environment."
      )
      .font(.callout)
      .foregroundStyle(.secondary)

      Text(AgentLaunchCommand.render(profile: profile))
        .font(.system(.callout, design: .monospaced))
        .textSelection(.enabled)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityLabel("Launch command")
    }
  }

  // MARK: - Details

  private var detailsSection: some View {
    Section("Details") {
      if !descriptor.models.isEmpty {
        choicePicker(
          title: "Model",
          choices: descriptor.models,
          selection: binding(\.modelID)
        )
      }
      if !descriptor.reasoningEfforts.isEmpty {
        choicePicker(
          title: "Reasoning Effort",
          choices: descriptor.reasoningEfforts,
          selection: binding(\.reasoningEffortID)
        )
      }
      if descriptor.executionModes.count > 1 {
        Picker("Execution Mode", selection: executionModeBinding) {
          ForEach(descriptor.executionModes) { mode in
            Text(mode.label).tag(mode.id)
          }
        }
      }
      Picker("Open In", selection: openInBinding) {
        ForEach(AgentOpenTarget.allCases, id: \.self) { option in
          Text(option.label).tag(option)
        }
      }
    }
  }

  /// Picker over an optional override where `nil` means "let the agent
  /// decide" — codans contributes no flag in that case.
  private func choicePicker(
    title: String,
    choices: [AgentLaunchChoice],
    selection: Binding<String?>
  ) -> some View {
    Picker(title, selection: selection) {
      Text("Runtime default").tag(String?.none)
      ForEach(choices) { choice in
        Text(choice.label).tag(String?(choice.id))
      }
    }
  }

  // MARK: - Advanced

  private var advancedSection: some View {
    Section("Advanced") {
      LabeledContent("Extra Arguments") {
        TextField("", text: binding(\.extraArguments), prompt: Text(verbatim: "--flag value"))
          .textFieldStyle(.plain)
          .multilineTextAlignment(.trailing)
          .font(.system(.body, design: .monospaced))
      }

      // Header row for the variables list below. `EnvironmentEditorView`
      // contributes sibling rows (one per variable plus its own Add row), so
      // the group needs a title of its own to read as one control.
      VStack(alignment: .leading, spacing: 2) {
        Text("Environment Variables")
        Text(
          "Applied only to the launched agent — the pane's shell keeps your normal environment."
        )
        .font(.callout)
        .foregroundStyle(.secondary)
      }
      .frame(maxWidth: .infinity, alignment: .leading)

      EnvironmentEditorView(
        envVars: binding(\.envVars),
        onChange: { key, value in
          var updated = profile
          if let value {
            updated.envVars[key] = value
          } else {
            updated.envVars.removeValue(forKey: key)
          }
          onChange(updated)
        }
      )

      Toggle("Use Dedicated Home", isOn: binding(\.usesDedicatedHome))
    }
  }

  // MARK: - Bindings

  /// Generic write-through binding: read the field off the current profile,
  /// write a whole updated profile back through `onChange`.
  private func binding<Value>(
    _ keyPath: WritableKeyPath<AgentProfile, Value>
  ) -> Binding<Value> {
    Binding(
      get: { profile[keyPath: keyPath] },
      set: { newValue in
        var updated = profile
        updated[keyPath: keyPath] = newValue
        onChange(updated)
      }
    )
  }

  /// Swapping the agent invalidates every option id the old agent defined,
  /// so the three override fields reset rather than persisting flags the new
  /// CLI does not understand.
  private var kindBinding: Binding<AgentKind> {
    Binding(
      get: { profile.kind },
      set: { newKind in
        guard newKind != profile.kind else { return }
        var updated = profile
        updated.kind = newKind
        updated.modelID = nil
        updated.reasoningEffortID = nil
        updated.executionModeID = nil
        onChange(updated)
      }
    )
  }

  /// Execution mode is never absent — a profile with no stored mode resolves
  /// to the descriptor's first (Standard) entry.
  private var executionModeBinding: Binding<String> {
    Binding(
      get: { descriptor.executionMode(id: profile.executionModeID)?.id ?? "" },
      set: { newValue in
        var updated = profile
        updated.executionModeID = newValue
        onChange(updated)
      }
    )
  }

  private var openInBinding: Binding<AgentOpenTarget> {
    Binding(
      get: { AgentOpenTarget(target: profile.target, direction: profile.direction) },
      set: { option in
        var updated = profile
        updated.target = option.target
        if let direction = option.direction {
          updated.direction = direction
        }
        onChange(updated)
      }
    )
  }
}

/// Flattened "Open In" choice. `ScriptTarget` + `ScriptSplitDirection` is the
/// right persisted shape (it is what the script dispatcher consumes) but a
/// two-picker UI for one decision reads worse than one list, so the view
/// collapses the pair here.
enum AgentOpenTarget: Hashable, CaseIterable {
  case newTab
  case currentPane
  case splitRight
  case splitLeft
  case splitDown
  case splitUp

  init(target: ScriptTarget, direction: ScriptSplitDirection) {
    switch target {
    case .newTab:
      self = .newTab
    case .focused:
      self = .currentPane
    case .split:
      switch direction {
      case .right: self = .splitRight
      case .left: self = .splitLeft
      case .down: self = .splitDown
      case .up: self = .splitUp
      }
    }
  }

  var target: ScriptTarget {
    switch self {
    case .newTab: return .newTab
    case .currentPane: return .focused
    case .splitRight, .splitLeft, .splitDown, .splitUp: return .split
    }
  }

  var direction: ScriptSplitDirection? {
    switch self {
    case .newTab, .currentPane: return nil
    case .splitRight: return .right
    case .splitLeft: return .left
    case .splitDown: return .down
    case .splitUp: return .up
    }
  }

  var label: String {
    switch self {
    case .newTab: return "New Tab"
    case .currentPane: return "Current Pane"
    case .splitRight: return "Split Right"
    case .splitLeft: return "Split Left"
    case .splitDown: return "Split Down"
    case .splitUp: return "Split Up"
    }
  }
}

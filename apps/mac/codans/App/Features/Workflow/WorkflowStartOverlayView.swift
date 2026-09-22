import CodansCore
import ComposableArchitecture
import SwiftUI

/// Floating card hosting the workflow start panel, presented over the main
/// split the same way the Hand Off chooser and the Command Palette are. One
/// step: bind the roles, fill the inputs, tick any step to leave out, and
/// Run — the card closes and the engine takes over. Escape cancels, Return
/// runs once the form is valid.
struct WorkflowStartOverlayView: View {
  @Bindable var store: StoreOf<WorkflowStartFeature>

  private let cardCornerRadius: CGFloat = 12
  @FocusState private var cardFocused: Bool

  var body: some View {
    ZStack(alignment: .top) {
      Color.clear
        .contentShape(.rect)
        .onTapGesture { store.send(.cancelTapped) }
        .accessibilityAddTraits(.isButton)
        .accessibilityLabel("Dismiss Run Workflow")

      VStack(alignment: .leading, spacing: 0) {
        header
        Divider()
        if let trust = store.trust {
          trustCard(trust)
        } else {
          form
        }
        Divider()
        footer
      }
      .frame(maxWidth: 520)
      .floatingCard(cornerRadius: cardCornerRadius)
      .padding(.top, 80)
      .focusable()
      .focusEffectDisabled()
      .focused($cardFocused)
      .onKeyPress(.return) {
        store.send(store.trust == nil ? .runTapped : .trustAndRunTapped)
        return .handled
      }
      .onKeyPress(.escape) {
        store.send(.cancelTapped)
        return .handled
      }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .onAppear { cardFocused = true }
  }

  // MARK: - Header

  private var header: some View {
    VStack(alignment: .leading, spacing: 2) {
      Text(store.workflowName)
        .font(.headline)
      if let description = store.definition.description, !description.isEmpty {
        Text(description)
          .font(.subheadline)
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
      }
      Text("Runs in \(store.source.worktreeName)")
        .font(.subheadline)
        .foregroundStyle(.secondary)
    }
    .padding(16)
    .frame(maxWidth: .infinity, alignment: .leading)
  }

  // MARK: - Form

  private var form: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 14) {
        if store.isEmptyForm {
          Text("This workflow takes no roles or inputs.")
            .font(.callout)
            .foregroundStyle(.secondary)
        }
        if !store.roles.isEmpty {
          section("Roles") {
            ForEach(store.roles) { role in
              roleRow(role)
            }
          }
        }
        if !store.inputs.isEmpty {
          section("Inputs") {
            ForEach(store.inputs) { row in
              inputRow(row)
            }
          }
        }
        if !store.skippable.isEmpty {
          section("Skip steps") {
            ForEach(store.skippable) { row in
              skipRow(row)
            }
          }
        }
      }
      .padding(16)
      .frame(maxWidth: .infinity, alignment: .leading)
    }
    .fixedSize(horizontal: false, vertical: true)
    .frame(maxHeight: 380)
  }

  private func section<Content: View>(
    _ title: String, @ViewBuilder content: () -> Content
  ) -> some View {
    VStack(alignment: .leading, spacing: 6) {
      Text(title)
        .font(.caption)
        .foregroundStyle(.secondary)
      content()
    }
  }

  // MARK: - Roles

  @ViewBuilder
  private func roleRow(_ role: WorkflowStartFeature.RoleRow) -> some View {
    HStack(alignment: .firstTextBaseline, spacing: 10) {
      Text(role.name)
        .font(.body)
        .frame(width: 110, alignment: .leading)
      switch role.source {
      case .launch:
        launchPicker(role)
      case .pick:
        pickPicker(role)
      case .current:
        Text(store.source.paneLabel ?? "No agent pane focused")
          .font(.callout)
          .foregroundStyle(store.source.paneLabel == nil ? .secondary : .primary)
        Spacer(minLength: 0)
      }
    }
    .accessibilityIdentifier("workflowStart.role.\(role.name)")
  }

  @ViewBuilder
  private func launchPicker(_ role: WorkflowStartFeature.RoleRow) -> some View {
    if role.profiles.isEmpty {
      Text("No enabled profile qualifies")
        .font(.callout)
        .foregroundStyle(.secondary)
      Spacer(minLength: 0)
    } else {
      Picker(
        "Profile",
        selection: Binding(
          get: { role.profileID },
          set: { store.send(.setProfile(role: role.name, profileID: $0)) })
      ) {
        Text("Choose…").tag(UUID?.none)
        ForEach(role.profiles) { profile in
          Text("\(profile.name) · \(profile.agent.displayName)").tag(UUID?.some(profile.id))
        }
      }
      .pickerStyle(.menu)
      .labelsHidden()
      .controlSize(.small)
      .help("Which Agent Profile codans launches for \"\(role.name)\"")
    }
  }

  @ViewBuilder
  private func pickPicker(_ role: WorkflowStartFeature.RoleRow) -> some View {
    if role.panes.isEmpty {
      Text("No free agent pane in this worktree")
        .font(.callout)
        .foregroundStyle(.secondary)
      Spacer(minLength: 0)
    } else {
      Picker(
        "Pane",
        selection: Binding(
          get: { role.paneID },
          set: { store.send(.setPane(role: role.name, paneID: $0)) })
      ) {
        Text("Choose…").tag(PaneID?.none)
        ForEach(role.panes) { pane in
          Text("\(pane.label) · \(pane.agent.displayName)").tag(PaneID?.some(pane.id))
        }
      }
      .pickerStyle(.menu)
      .labelsHidden()
      .controlSize(.small)
      .help("Which running agent plays \"\(role.name)\"")
    }
  }

  // MARK: - Inputs

  @ViewBuilder
  private func inputRow(_ row: WorkflowStartFeature.InputRow) -> some View {
    HStack(alignment: .firstTextBaseline, spacing: 10) {
      Text(row.input.name)
        .font(.body)
        .frame(width: 110, alignment: .leading)
      inputControl(row)
    }
    .help(row.input.description ?? "")
    .accessibilityIdentifier("workflowStart.input.\(row.input.name)")
  }

  @ViewBuilder
  private func inputControl(_ row: WorkflowStartFeature.InputRow) -> some View {
    let text = Binding(
      get: { row.text },
      set: { store.send(.setInput(name: row.input.name, text: $0)) })
    switch row.input.kind {
    case .boolean:
      Toggle("", isOn: Binding(get: { row.text == "true" }, set: { text.wrappedValue = $0 ? "true" : "false" }))
        .labelsHidden()
        .toggleStyle(.switch)
        .controlSize(.small)
      Spacer(minLength: 0)
    case .choice:
      Picker("", selection: text) {
        Text("Choose…").tag("")
        ForEach(row.input.options, id: \.self) { option in
          Text(option).tag(option)
        }
      }
      .pickerStyle(.menu)
      .labelsHidden()
      .controlSize(.small)
    case .string, .number:
      TextField(row.input.kind == .number ? rangeHint(row.input) : "", text: text)
        .textFieldStyle(.roundedBorder)
        .controlSize(.small)
    }
  }

  private func rangeHint(_ input: WorkflowInput) -> String {
    switch (input.min, input.max) {
    case (let min?, let max?): return "\(min)–\(max)"
    case (let min?, nil): return "≥ \(min)"
    case (nil, let max?): return "≤ \(max)"
    case (nil, nil): return "number"
    }
  }

  // MARK: - Skips

  private func skipRow(_ row: WorkflowStartFeature.SkipRow) -> some View {
    VStack(alignment: .leading, spacing: 2) {
      Toggle(
        isOn: Binding(
          get: { store.skipped.contains(row.stepID) },
          set: { store.send(.setSkipped(stepID: row.stepID, $0)) })
      ) {
        Text(row.title)
          .font(.callout)
      }
      .toggleStyle(.checkbox)
      if let consequence = store.state.consequence(for: row) {
        Text(consequence)
          .font(.caption)
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
          .padding(.leading, 20)
      }
    }
    .accessibilityIdentifier("workflowStart.skip.\(row.stepID)")
  }

  // MARK: - Trust

  private func trustCard(_ trust: WorkflowStartFeature.TrustPrompt) -> some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 8) {
        Text("This workflow comes from the repository and runs shell commands.")
          .font(.callout)
          .fixedSize(horizontal: false, vertical: true)
        Text(trust.path)
          .font(.caption.monospaced())
          .foregroundStyle(.secondary)
          .textSelection(.enabled)
          .fixedSize(horizontal: false, vertical: true)
        ForEach(Array(trust.commands.enumerated()), id: \.offset) { _, command in
          Text(command)
            .font(.caption.monospaced())
            .textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.quaternary, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
        }
        Text("Trusting is remembered for this exact file; any edit asks again.")
          .font(.caption)
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
      }
      .padding(16)
      .frame(maxWidth: .infinity, alignment: .leading)
    }
    .fixedSize(horizontal: false, vertical: true)
    .frame(maxHeight: 380)
    .accessibilityIdentifier("workflowStart.trust")
  }

  // MARK: - Footer

  private var footer: some View {
    VStack(alignment: .leading, spacing: 6) {
      if let message = store.message {
        Text(message)
          .font(.caption)
          .foregroundStyle(.orange)
          .fixedSize(horizontal: false, vertical: true)
          .accessibilityIdentifier("workflowStart.message")
      } else if store.trust == nil, let hint = store.state.validationMessage {
        Text(hint)
          .font(.caption)
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
          .accessibilityIdentifier("workflowStart.hint")
      }
      ForEach(store.diagnostics, id: \.self) { line in
        Text(line)
          .font(.caption.monospaced())
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
      }
      HStack(spacing: 12) {
        Spacer()
        Button("Cancel") { store.send(.cancelTapped) }
          .keyboardShortcut(.cancelAction)
        if store.trust != nil {
          Button("Trust and Run") { store.send(.trustAndRunTapped) }
            .buttonStyle(.borderedProminent)
            .accessibilityIdentifier("workflowStart.trustAndRun")
        } else {
          Button("Run") { store.send(.runTapped) }
            .buttonStyle(.borderedProminent)
            .disabled(!store.canRun)
            .accessibilityIdentifier("workflowStart.run")
        }
      }
    }
    .padding(12)
  }
}

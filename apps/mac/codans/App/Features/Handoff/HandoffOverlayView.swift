import CodansCore
import ComposableArchitecture
import SwiftUI

/// Floating card hosting the Hand Off chooser, presented over the main split
/// the same way the Command Palette is. One step: pick the receiver, the
/// placement, and Brief or Context, and the card closes; `RootFeature` does
/// the work and lands on the receiver. The card owns the keyboard (arrows,
/// Return, Escape) and a click outside dismisses it.
struct HandoffOverlayView: View {
  @Bindable var store: StoreOf<HandoffFeature>

  private let cardCornerRadius: CGFloat = 12
  @FocusState private var cardFocused: Bool

  var body: some View {
    ZStack(alignment: .top) {
      Color.clear
        .contentShape(.rect)
        .onTapGesture { store.send(.cancelTapped) }
        .accessibilityAddTraits(.isButton)
        .accessibilityLabel("Dismiss Hand Off")

      VStack(alignment: .leading, spacing: 0) {
        header
        Divider()
        chooser
      }
      .frame(maxWidth: 520)
      .floatingCard(cornerRadius: cardCornerRadius)
      .padding(.top, 80)
      .focusable()
      .focusEffectDisabled()
      .focused($cardFocused)
      .onKeyPress(.upArrow) { keyMove(.up) }
      .onKeyPress(.downArrow) { keyMove(.down) }
      .onKeyPress(.leftArrow) { keyMove(.left) }
      .onKeyPress(.rightArrow) { keyMove(.right) }
      .onKeyPress(.return) {
        store.send(.confirmSelection)
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
      Text("Hand Off")
        .font(.headline)
      Text(
        "Pass this task to another agent. Hand Off with Brief asks \(store.source.agentName) to write "
          + "its briefing first; Hand Off with Context starts the receiver now from generated context."
      )
      .font(.subheadline)
      .foregroundStyle(.secondary)
      .fixedSize(horizontal: false, vertical: true)
    }
    .padding(16)
    .frame(maxWidth: .infinity, alignment: .leading)
  }

  // MARK: - Chooser

  /// Profiles in a two-column grid of names, the checkpoint row spanning the
  /// width beneath. Rows carry no description; the tooltip does.
  private var chooser: some View {
    let rows = Array(store.targets.enumerated())
    let profiles = rows.filter { $0.element.kind != .checkpoint }
    let checkpoints = rows.filter { $0.element.kind == .checkpoint }
    return VStack(alignment: .leading, spacing: 0) {
      VStack(alignment: .leading, spacing: 2) {
        if profiles.isEmpty {
          Text("No enabled agent to hand off to. Enable one under Settings › Agents.")
            .font(.caption)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
        } else {
          LazyVGrid(columns: gridColumns, alignment: .leading, spacing: 2) {
            ForEach(profiles, id: \.element.id) { index, target in
              targetRow(target, at: index)
            }
          }
        }
        ForEach(checkpoints, id: \.element.id) { index, target in
          targetRow(target, at: index)
        }
      }
      .padding(8)

      Divider()

      HStack(spacing: 12) {
        placementPicker
        Spacer()
        Button("Cancel") { store.send(.cancelTapped) }
          .keyboardShortcut(.cancelAction)
        confirmControl
      }
      .padding(12)
    }
  }

  private var gridColumns: [GridItem] {
    Array(
      repeating: GridItem(.flexible(), spacing: 2, alignment: .leading),
      count: HandoffFeature.State.columns)
  }

  private func targetRow(_ target: HandoffFeature.Target, at index: Int) -> some View {
    HandoffTargetRow(target: target, isSelected: index == store.selectedIndex) {
      store.send(.setSelectedIndex(index))
    }
  }

  /// Hand Off with Brief is the primary action; the chevron's menu offers
  /// Hand Off with Context, which starts the receiver now from generated
  /// context and never asks the agent. Return confirms the primary action.
  @ViewBuilder
  private var confirmControl: some View {
    if store.selectedTarget?.kind == .checkpoint {
      Button("Save Progress") { store.send(.confirmSelection) }
        .buttonStyle(.borderedProminent)
        .help("Ask \(store.source.agentName) to write a briefing checkpoint")
        .accessibilityIdentifier("handoff.confirm")
    } else {
      Menu {
        Button("Hand Off with Brief") { store.send(.confirmSelection) }
        Button("Hand Off with Context") { store.send(.confirmContextOnly) }
      } label: {
        Text("Hand Off with Brief")
      } primaryAction: {
        store.send(.confirmSelection)
      }
      .menuStyle(.button)
      .buttonStyle(.borderedProminent)
      .menuIndicator(.visible)
      .help(
        "Ask \(store.source.agentName) to write its briefing, then hand off to "
          + "\(store.selectedTarget?.title ?? "the agent"). The menu hands off now with generated context only."
      )
      .accessibilityIdentifier("handoff.confirm")
    }
  }

  /// Where the receiver opens: a target menu, and for a split a second menu
  /// for the side. Same pair the script command editor in Settings uses, minus
  /// "In Place" — a hand-off must never type over the outgoing agent's pane.
  private var placementPicker: some View {
    HStack(spacing: 8) {
      Picker("Open in", selection: targetSelection) {
        Text("New Tab").tag(ScriptTarget.newTab)
        Text("Split").tag(ScriptTarget.split)
      }
      .pickerStyle(.menu)
      .labelsHidden()
      .controlSize(.small)
      .fixedSize()
      .help("Where the receiving agent opens")
      .accessibilityIdentifier("handoff.placement")

      if store.placement.target == .split {
        Picker("Split Direction", selection: directionSelection) {
          Text("Right").tag(ScriptSplitDirection.right)
          Text("Down").tag(ScriptSplitDirection.down)
          Text("Left").tag(ScriptSplitDirection.left)
          Text("Up").tag(ScriptSplitDirection.up)
        }
        .pickerStyle(.menu)
        .labelsHidden()
        .controlSize(.small)
        .fixedSize()
        .help("Which side of this pane the split opens on")
        .accessibilityIdentifier("handoff.placement.direction")
      }
    }
  }

  /// Switching to Split keeps the direction already chosen, or starts on the
  /// right — beside the agent being handed off from, in a left-to-right layout.
  private var targetSelection: Binding<ScriptTarget> {
    Binding(
      get: { store.placement.target },
      set: { target in
        let placement: HandoffPlacement =
          target == .split ? .split(store.placement.direction ?? .right) : .newTab
        store.send(.setPlacement(placement))
      }
    )
  }

  private var directionSelection: Binding<ScriptSplitDirection> {
    Binding(
      get: { store.placement.direction ?? .right },
      set: { store.send(.setPlacement(.split($0))) }
    )
  }

  // MARK: - Interaction

  private func keyMove(_ move: HandoffFeature.Move) -> KeyPress.Result {
    store.send(.moveSelection(move))
    return .handled
  }
}

private struct HandoffTargetRow: View {
  let target: HandoffFeature.Target
  let isSelected: Bool
  let select: () -> Void

  var body: some View {
    Button(action: select) {
      HStack(spacing: 10) {
        if let icon = target.icon {
          AgentLogoView(icon: icon, size: 18, tint: .primary)
        } else {
          Image(systemName: "square.and.pencil")
            .foregroundStyle(.secondary)
            .frame(width: 18, height: 18)
            .accessibilityHidden(true)
        }
        Text(target.title)
          .font(.body)
          .lineLimit(1)
        if target.isSameAgent {
          Text("fresh session")
            .font(.caption2)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(.quaternary, in: Capsule())
        }
        Spacer(minLength: 0)
      }
      .padding(.horizontal, 10)
      .padding(.vertical, 7)
      .contentShape(.rect)
    }
    .buttonStyle(.plain)
    .help(target.help)
    .background(
      RoundedRectangle(cornerRadius: 8, style: .continuous)
        .fill(isSelected ? Color.accentColor.opacity(0.18) : Color.clear)
    )
    .overlay(
      RoundedRectangle(cornerRadius: 8, style: .continuous)
        .strokeBorder(isSelected ? Color.accentColor : Color.clear, lineWidth: 1)
    )
    .accessibilityAddTraits(isSelected ? [.isSelected] : [])
  }
}

import CodansCore
import ComposableArchitecture
import SwiftUI

/// Floating card hosting the Hand Off flow, presented over the main split
/// the same way the Command Palette is. The panel is a projection of
/// `HandoffFeature` state:
///
/// - *choosing* / *finished*: the card owns the keyboard (arrows, Return,
///   Escape) and a click outside dismisses it;
/// - *requesting*: the card is non-modal. The keyboard stays with the
///   terminal — the request may trigger a permission prompt the user has to
///   approve in the source agent — and a click outside collapses the card;
///   the hand-off still completes headlessly.
/// - *finishing*: the fallback transition has committed; no cancel.
struct HandoffOverlayView: View {
  @Bindable var store: StoreOf<HandoffFeature>

  private let cardCornerRadius: CGFloat = 12
  @FocusState private var cardFocused: Bool

  var body: some View {
    ZStack(alignment: .top) {
      Color.clear
        .contentShape(.rect)
        .onTapGesture { tapOutside() }
        .accessibilityAddTraits(.isButton)
        .accessibilityLabel("Dismiss Hand Off")

      VStack(alignment: .leading, spacing: 0) {
        header
        Divider()
        switch store.phase {
        case .choosing:
          chooseStep
        case .running(let run):
          runStep(run)
        case .finished(let outcome):
          finishedStep(outcome)
        }
      }
      .frame(maxWidth: 520)
      .floatingCard(cornerRadius: cardCornerRadius)
      .padding(.top, 80)
      // Keyboard ownership follows the phase; see the type doc.
      .focusable(capturesKeyboard)
      .focusEffectDisabled()
      .focused($cardFocused)
      .onKeyPress(.upArrow) { keyMove(-1) }
      .onKeyPress(.downArrow) { keyMove(1) }
      .onKeyPress(.return) { keyConfirm() }
      .onKeyPress(.escape) { keyEscape() }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .onAppear { cardFocused = true }
    .onChange(of: capturesKeyboard) { _, captures in
      cardFocused = captures
    }
  }

  // MARK: - Header

  private var header: some View {
    VStack(alignment: .leading, spacing: 2) {
      Text(headerTitle)
        .font(.headline)
      Text(headerSubtitle)
        .font(.subheadline)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
    }
    .padding(16)
    .frame(maxWidth: .infinity, alignment: .leading)
  }

  private var headerTitle: String {
    switch store.phase {
    case .choosing:
      return "Hand Off"
    case .running(let run):
      switch run.target.kind {
      case .profile: return "Handing off to \(run.target.title)"
      case .checkpoint: return "Saving progress"
      }
    case .finished(.handedOff(let name)):
      return "Handed off to \(name)"
    case .finished(.saved):
      return "Progress saved"
    case .finished(.failed):
      return "Hand off failed"
    }
  }

  private var headerSubtitle: String {
    let agent = store.source.agentName
    switch store.phase {
    case .choosing:
      return "Pass this task to another agent. \(agent) writes its own briefing first."
    case .running(let run):
      switch run.stage {
      case .requesting:
        return "Waiting for \(agent) to write its briefing and run the hand-off"
      case .finishing:
        return "Finishing the hand-off with generated context only"
      }
    case .finished(.handedOff):
      return "The receiving agent picks up the task \(placementPhrase)"
    case .finished(.saved):
      return "The current state is saved under .codans/handoff/ for a later hand-off"
    case .finished(.failed(let message)):
      return message
    }
  }

  // MARK: - Choose

  private var chooseStep: some View {
    VStack(alignment: .leading, spacing: 0) {
      VStack(spacing: 2) {
        ForEach(Array(store.targets.enumerated()), id: \.element.id) { index, target in
          HandoffTargetRow(target: target, isSelected: index == store.selectedIndex) {
            store.send(.setSelectedIndex(index))
          }
        }
      }
      .padding(8)

      Divider()

      HStack(spacing: 12) {
        placementPicker
        Spacer()
        Button("Cancel") { store.send(.cancelTapped) }
          .keyboardShortcut(.cancelAction)
        Button(continueTitle) { store.send(.confirmSelection) }
          .buttonStyle(.borderedProminent)
          .keyboardShortcut(.defaultAction)
      }
      .padding(12)
    }
  }

  /// Where the receiver opens. Two choices, not a direction picker: a split
  /// always goes to the right of the source pane, which is what "beside the
  /// agent I am handing off from" means in a left-to-right layout. The CLI
  /// keeps the full direction set for scripts.
  private var placementPicker: some View {
    HStack(spacing: 8) {
      Text("Open in")
        .font(.caption)
        .foregroundStyle(.secondary)
      Picker("Open in", selection: placementSelection) {
        Text("New Tab").tag(HandoffPlacement.newTab)
        Text("Split").tag(HandoffPlacement.split(.right))
      }
      .pickerStyle(.segmented)
      .labelsHidden()
      .controlSize(.small)
      .fixedSize()
      .accessibilityIdentifier("handoff.placement")
    }
  }

  /// Any remembered split maps onto the picker's one split tag; the choice the
  /// picker writes back is exactly one of its two tags.
  private var placementSelection: Binding<HandoffPlacement> {
    Binding(
      get: { store.placement.target == .split ? .split(.right) : .newTab },
      set: { store.send(.setPlacement($0)) }
    )
  }

  private var placementPhrase: String {
    switch store.placement {
    case .newTab: return "in a new tab"
    case .split: return "in a split beside this pane"
    }
  }

  private var continueTitle: String {
    guard store.targets.indices.contains(store.selectedIndex) else { return "Continue" }
    let target = store.targets[store.selectedIndex]
    switch target.kind {
    case .profile: return "Hand Off to \(target.title)"
    case .checkpoint: return "Save Progress"
    }
  }

  // MARK: - Running

  private func runStep(_ run: HandoffFeature.Run) -> some View {
    VStack(alignment: .leading, spacing: 0) {
      HStack(spacing: 10) {
        ProgressView()
          .controlSize(.small)
        Text(stageDescription(run))
          .font(.body)
          .fixedSize(horizontal: false, vertical: true)
        Spacer(minLength: 0)
      }
      .padding(16)

      Divider()

      HStack {
        Text(
          run.stage == .requesting
            ? "The request is queued if \(store.source.agentName) is busy."
            : "This hand-off has started and will finish in the background."
        )
        .font(.caption)
        .foregroundStyle(.secondary)
        Spacer()
        if run.stage == .requesting {
          Button("Context Only") { store.send(.contextOnlyTapped) }
            .help("Don't wait: hand off with generated context only, no briefing")
          Button("Cancel") { store.send(.cancelTapped) }
            .help("Close this panel; if \(store.source.agentName) still hands off, it completes in the background")
        }
      }
      .padding(12)
    }
  }

  private func stageDescription(_ run: HandoffFeature.Run) -> String {
    switch run.stage {
    case .requesting:
      switch run.target.kind {
      case .profile:
        return "Asked \(store.source.agentName) to write its briefing and hand off to \(run.target.title)"
      case .checkpoint:
        return "Asked \(store.source.agentName) to write a briefing checkpoint"
      }
    case .finishing:
      return "Archiving the previous round and starting the receiver"
    }
  }

  // MARK: - Finished

  private func finishedStep(_ outcome: HandoffFeature.Outcome) -> some View {
    VStack(alignment: .leading, spacing: 0) {
      HStack(spacing: 10) {
        switch outcome {
        case .handedOff, .saved:
          Image(systemName: "checkmark.circle.fill")
            .foregroundStyle(.green)
            .font(.title2)
            .accessibilityLabel("Success")
        case .failed:
          Image(systemName: "exclamationmark.triangle.fill")
            .foregroundStyle(.yellow)
            .font(.title2)
            .accessibilityLabel("Failure")
        }
        Text(finishedMessage(outcome))
          .font(.body)
        Spacer(minLength: 0)
      }
      .padding(16)

      Divider()

      HStack {
        Spacer()
        Button("Close") { store.send(.closeTapped) }
          .buttonStyle(.borderedProminent)
          .keyboardShortcut(.defaultAction)
      }
      .padding(12)
    }
  }

  private func finishedMessage(_ outcome: HandoffFeature.Outcome) -> String {
    switch outcome {
    case .handedOff(let name): return "\(name) started \(placementPhrase)"
    case .saved: return "Hand-off notes are up to date"
    case .failed: return "Nothing was launched"
    }
  }

  // MARK: - Interaction

  private var capturesKeyboard: Bool {
    switch store.phase {
    case .choosing, .finished: return true
    case .running: return false
    }
  }

  private func tapOutside() {
    switch store.phase {
    case .choosing:
      store.send(.cancelTapped)
    case .finished:
      store.send(.closeTapped)
    case .running(let run) where run.stage == .requesting:
      store.send(.cancelTapped)
    case .running:
      break
    }
  }

  private func keyMove(_ delta: Int) -> KeyPress.Result {
    guard store.isChoosing else { return .ignored }
    store.send(.moveSelection(delta: delta))
    return .handled
  }

  private func keyConfirm() -> KeyPress.Result {
    switch store.phase {
    case .choosing:
      store.send(.confirmSelection)
      return .handled
    case .finished:
      store.send(.closeTapped)
      return .handled
    case .running:
      return .ignored
    }
  }

  private func keyEscape() -> KeyPress.Result {
    switch store.phase {
    case .choosing:
      store.send(.cancelTapped)
      return .handled
    case .finished:
      store.send(.closeTapped)
      return .handled
    case .running:
      return .ignored
    }
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
        VStack(alignment: .leading, spacing: 1) {
          HStack(spacing: 6) {
            Text(target.title)
              .font(.body)
            if target.isSameAgent {
              Text("fresh session")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 5)
                .padding(.vertical, 1)
                .background(.quaternary, in: Capsule())
            }
          }
          Text(target.subtitle)
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        Spacer(minLength: 0)
      }
      .padding(.horizontal, 10)
      .padding(.vertical, 7)
      .contentShape(.rect)
    }
    .buttonStyle(.plain)
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

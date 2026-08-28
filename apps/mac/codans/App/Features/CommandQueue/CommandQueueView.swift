import CodansCore
import ComposableArchitecture
import SwiftUI

/// Sheet-hosted editor for a Pane's Command Queue (⌘⌥L, or a click on the
/// pane's queue badge).
///
/// Presented with `.sheet(item:)` like the app's other dialogs rather than as
/// a floating overlay: it inherits the standard container metrics
/// (`padding(24)`, fixed width, headline + caption header, trailing
/// Cancel / default-action footer) from `TabRenameSheetView` and friends, and
/// a real AppKit presentation lets the controls be native — a segmented
/// `Picker` layered over the terminal's Metal surface in a `ZStack` was what
/// forced the hand-drawn selector this replaces.
///
/// The queued list is read from the live catalog rather than from reducer
/// state: an entry that drains while the sheet is open should vanish from the
/// list on the same frame it is typed into the terminal.
struct CommandQueueView: View {
  @Bindable var store: StoreOf<CommandQueueFeature>
  /// Sent by Cancel. Dismissal is "parent nils the `@Presents` slot".
  let onDismiss: () -> Void

  @Environment(HierarchyManager.self) private var hierarchyManager
  @FocusState private var draftFocused: Bool

  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      header
      composer
      if !entries.isEmpty {
        queuedSection
      }
      footer
    }
    .padding(24)
    .frame(width: 460)
    .onAppear { draftFocused = true }
  }

  // MARK: - Header

  private var header: some View {
    VStack(alignment: .leading, spacing: 4) {
      Text("Command Queue")
        .font(.headline)
      Text(subtitle)
        .font(.caption)
        .foregroundStyle(.secondary)
        .lineLimit(1)
        .truncationMode(.middle)
    }
  }

  /// Names the pane being edited. Truncates in the middle so a long worktree
  /// path keeps both its project and its branch visible.
  private var subtitle: String {
    guard let paneLabel else { return "Commands wait here until this pane is ready." }
    return "Queued on \(paneLabel)."
  }

  // MARK: - Composer

  private var composer: some View {
    VStack(alignment: .leading, spacing: 8) {
      // Single-line by design: one entry is one command and one Return. A
      // multi-line draft would put embedded newlines into the delivered
      // text, and each of those submits on its own — the first line would
      // fire and the rest would arrive as separate prompts.
      TextField("Command to send…", text: $store.draft.sending(\.draftChanged))
        .textFieldStyle(.roundedBorder)
        .focused($draftFocused)

      Picker("", selection: $store.mode.sending(\.modeChanged)) {
        ForEach(CommandQueueFeature.State.Mode.allCases, id: \.self) { mode in
          Text(mode.title).tag(mode)
        }
      }
      .pickerStyle(.segmented)
      .labelsHidden()

      if store.mode == .scheduled {
        scheduleControls
          .padding(.top, 2)
      }

      Text(modeHint)
        .font(.caption)
        .foregroundStyle(.secondary)
    }
  }

  private var scheduleControls: some View {
    VStack(alignment: .leading, spacing: 8) {
      HStack(spacing: 8) {
        Text("At")
          .font(.callout)
          .foregroundStyle(.secondary)
        DatePicker(
          "",
          selection: $store.scheduledAt.sending(\.scheduledAtChanged),
          displayedComponents: [.date, .hourAndMinute]
        )
        .labelsHidden()
        // `.field`, not `.compact`: a stepper field is typeable, needs no
        // popover, and matches the Date & Time idiom this reads as.
        .datePickerStyle(.field)
      }

      HStack(spacing: 8) {
        Toggle(
          "Repeat every",
          isOn: $store.repeatEnabled.sending(\.repeatEnabledChanged)
        )
        .font(.callout)
        TextField(
          "",
          value: $store.repeatAmount.sending(\.repeatAmountChanged),
          format: .number
        )
        .textFieldStyle(.roundedBorder)
        .frame(width: 52)
        .disabled(!store.repeatEnabled)
        Picker("", selection: $store.repeatUnit.sending(\.repeatUnitChanged)) {
          ForEach(CommandQueueFeature.IntervalUnit.allCases, id: \.self) { unit in
            Text(unit.title).tag(unit)
          }
        }
        .labelsHidden()
        .frame(width: 96)
        .disabled(!store.repeatEnabled)
      }
    }
  }

  private var modeHint: String {
    switch store.mode {
    case .now:
      return "Typed into the pane right away."
    case .afterCurrentTask:
      return "Waits until the pane finishes what it is doing."
    case .scheduled:
      return store.repeatInterval == nil
        ? "Fires once at the chosen time."
        : "Fires at the chosen time, then repeats."
    }
  }

  // MARK: - Queued list

  private var queuedSection: some View {
    VStack(alignment: .leading, spacing: 6) {
      HStack(spacing: 6) {
        Text("Queued")
          .font(.subheadline.weight(.medium))
        Text("\(entries.count)")
          .font(.subheadline)
          .foregroundStyle(.secondary)
          .monospacedDigit()
        Spacer()
        Button("Clear All") { store.send(.clearAllTapped) }
          .buttonStyle(.link)
          .font(.caption)
      }

      ScrollView {
        VStack(spacing: 0) {
          ForEach(Array(entries.enumerated()), id: \.element.id) { index, entry in
            if index > 0 { Divider() }
            row(entry)
          }
        }
      }
      .scrollIndicators(.automatic)
      .frame(maxHeight: 150)
      .background(
        RoundedRectangle(cornerRadius: 6, style: .continuous)
          .fill(Color(nsColor: .textBackgroundColor))
      )
      .overlay(
        RoundedRectangle(cornerRadius: 6, style: .continuous)
          .stroke(Color(nsColor: .separatorColor), lineWidth: 1)
      )
    }
  }

  private func row(_ entry: QueuedCommand) -> some View {
    HStack(spacing: 8) {
      Image(systemName: entry.timing.fireDate == nil ? "arrow.turn.down.right" : "clock")
        .font(.caption)
        .frame(width: 14)
        .foregroundStyle(.secondary)
        .accessibilityHidden(true)
      VStack(alignment: .leading, spacing: 1) {
        Text(entry.text)
          .font(.system(size: 12, design: .monospaced))
          .lineLimit(1)
          .truncationMode(.middle)
        Text(CommandQueueBadgeStyle.description(of: entry.timing))
          .font(.caption)
          .foregroundStyle(.secondary)
      }
      Spacer(minLength: 8)
      Button {
        store.send(.removeTapped(entry.id))
      } label: {
        Image(systemName: "xmark.circle.fill")
          .foregroundStyle(.secondary)
      }
      .buttonStyle(.plain)
      .accessibilityLabel("Remove queued command")
    }
    .padding(.horizontal, 8)
    .padding(.vertical, 6)
  }

  // MARK: - Footer

  /// Cancel closes the sheet and discards the draft — it does not undo
  /// entries already added, which land in the catalog the moment the default
  /// button is pressed. The default button stays put rather than dismissing,
  /// because queueing several commands in one sitting is the common case.
  private var footer: some View {
    HStack {
      Spacer()
      Button("Cancel", role: .cancel) { onDismiss() }
        .keyboardShortcut(.cancelAction)
      Button(store.mode == .now ? "Send" : "Add to Queue") {
        store.send(.submitted)
      }
      .keyboardShortcut(.defaultAction)
      .buttonStyle(.borderedProminent)
      .disabled(!store.canSubmit)
    }
  }

  // MARK: - Catalog reads

  /// Live queue for the edited pane. Read inside `body`'s tracking scope so
  /// `@Observable` re-renders the list when the runner drains an entry.
  private var entries: [QueuedCommand] {
    hierarchyManager.catalog.pane(store.paneID)?.commandQueue ?? []
  }

  /// Best-effort human label for the pane being edited — the tab's name if it
  /// has one, else its cached live title, else the pane's cwd basename.
  private var paneLabel: String? {
    for project in hierarchyManager.catalog.projects {
      for worktree in project.worktrees {
        for tab in worktree.tabs {
          guard let pane = tab.panes.first(where: { $0.id == store.paneID }) else { continue }
          if let name = tab.name, !name.isEmpty { return name }
          if let cached = tab.cachedDisplayTitle, !cached.isEmpty { return cached }
          return URL(fileURLWithPath: pane.workingDirectory).lastPathComponent
        }
      }
    }
    return nil
  }
}

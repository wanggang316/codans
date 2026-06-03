import ComposableArchitecture
import SwiftUI
import TouchCodeCore

/// Overlay UI for the Command Palette. Presented as a floating card
/// centered near the top of the window, over whatever the
/// `NavigationSplitView` is currently showing. Dismissal is driven by
/// the parent reducer's `@Presents` pattern — activating a row or
/// pressing Escape sends a state-clear back up so the `if let` wrapper
/// removes this view from the tree.
struct CommandPaletteView: View {
  @Bindable var store: StoreOf<CommandPaletteFeature>
  /// Sent by the parent when Esc / scrim / activation requests dismiss.
  /// We don't carry a `.dismissed` reducer action here because dismissal
  /// is just "parent nil-out the @Presents slot" — the feature itself
  /// has no teardown work to do.
  let onDismiss: () -> Void

  @Environment(\.resolvedShortcuts) private var resolvedShortcuts
  @FocusState private var queryFocused: Bool

  var body: some View {
    ZStack(alignment: .top) {
      // Invisible click-catcher. No transition applied — the hit-area is already
      // transparent, so animating its opacity is wasted work that delays the
      // perceived appearance of the card.
      Color.clear
        .contentShape(.rect)
        .onTapGesture { onDismiss() }
        .accessibilityAddTraits(.isButton)
        .accessibilityLabel("Dismiss Command Palette")

      VStack(spacing: 0) {
        queryField
        // Hide divider + list until indexing finishes. The card collapses to
        // just the search field on first appear, which paints in one tick;
        // rows slot in below once `.indexed` resolves.
        if store.isIndexed {
          Divider()
          resultList
        }
      }
      .frame(maxWidth: 560)
      .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 10))
      .overlay(
        RoundedRectangle(cornerRadius: 10)
          .stroke(Color(nsColor: .tertiaryLabelColor).opacity(0.5), lineWidth: 0.5)
      )
      .padding(.top, 80)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .onAppear { queryFocused = true }
  }

  private var queryField: some View {
    HStack(spacing: 8) {
      Image(systemName: "magnifyingglass")
        .foregroundStyle(.secondary)
        .accessibilityHidden(true)
      TextField(
        "Quick action…",
        text: $store.query.sending(\.queryChanged)
      )
      .textFieldStyle(.plain)
      .font(.system(size: 15))
      .focused($queryFocused)
      .onKeyPress(.escape) {
        onDismiss()
        return .handled
      }
      .onKeyPress(.upArrow) {
        store.send(.selectionMoved(.up))
        return .handled
      }
      .onKeyPress(.downArrow) {
        store.send(.selectionMoved(.down))
        return .handled
      }
      .onSubmit { store.send(.selectionCommitted) }
    }
    .padding(.horizontal, 14)
    .frame(height: 48)
  }

  @ViewBuilder
  private var resultList: some View {
    if store.filtered.isEmpty {
      Text(store.query.isEmpty ? "No commands available." : "No matching commands.")
        .font(.callout)
        .foregroundStyle(.secondary)
        .padding(24)
        .frame(maxWidth: .infinity)
    } else {
      ScrollViewReader { proxy in
        ScrollView {
          VStack(spacing: 1) {
            ForEach(store.filtered) { item in
              row(item, selected: item.id == store.selectionID)
                .id(item.id)
                .contentShape(Rectangle())
                .onTapGesture { store.send(.rowTapped(item.id)) }
                .accessibilityAddTraits(.isButton)
                .accessibilityLabel(item.title)
                .accessibilityHint(item.subtitle ?? "")
            }
          }
          .padding(.horizontal, 6)
          .padding(.vertical, 6)
        }
        .scrollIndicators(.never)
        .frame(maxHeight: 360)
        .onChange(of: store.selectionID) { _, newID in
          guard let newID else { return }
          withAnimation(.easeOut(duration: 0.12)) {
            proxy.scrollTo(newID, anchor: .center)
          }
        }
      }
    }
  }

  private func row(_ item: CommandPaletteItem, selected: Bool) -> some View {
    HStack(spacing: 10) {
      Image(systemName: item.icon)
        .frame(width: 20)
        .foregroundStyle(.secondary)
        .accessibilityHidden(true)
      VStack(alignment: .leading, spacing: 2) {
        Text(item.title).font(.system(size: 13))
        if let subtitle = item.subtitle {
          Text(subtitle).font(.caption).foregroundStyle(.secondary)
        }
      }
      Spacer()
      if let chord = chordDisplay(for: item) {
        Text(chord)
          .font(.system(size: 11, design: .monospaced))
          .foregroundStyle(.secondary)
      }
    }
    .padding(.horizontal, 10)
    .padding(.vertical, 8)
    .background(
      RoundedRectangle(cornerRadius: 8, style: .continuous)
        .fill(selected ? Color(nsColor: .unemphasizedSelectedContentBackgroundColor) : .clear)
    )
  }

  /// Prefer the registry-derived chord when the item declares a `commandID` and the resolved
  /// map has an enabled binding. Falls back to the literal `KeyEquivalentDescriptor` —
  /// retained so per-script and ad-hoc items can still surface a hint without a registry
  /// entry.
  private func chordDisplay(for item: CommandPaletteItem) -> String? {
    if let id = item.commandID,
      let resolved = resolvedShortcuts[id], resolved.isEnabled,
      let binding = resolved.binding
    {
      return ShortcutDisplay.chord(for: binding)
    }
    return item.shortcut.map { $0.keys.joined() }
  }
}

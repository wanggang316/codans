import SwiftUI

/// Drop-in replacement for the previous `.menu` Picker used in
/// Settings → Terminal. Renders a `LabeledContent` row whose trailing control
/// is a popup-button-styled control that opens a popover containing:
///   • a scrollable list of themes (each row: 6-color swatch + name)
///   • a side preview pane updated live as the cursor hovers a row
///
/// We replace `.menu` Picker because macOS strips custom content from menu
/// items, so inline swatches and per-item hover tracking aren't possible
/// inside a stock SwiftUI Menu. The popover gives us both.
struct ThemePickerButton: View {
  let title: String
  let options: [String]
  let previews: [String: GhosttyThemePreview]
  let selection: String?
  let isDisabled: Bool
  let onPick: (String?) -> Void

  @State private var isPopoverPresented = false

  var body: some View {
    LabeledContent(title) {
      Button {
        isPopoverPresented = true
      } label: {
        triggerLabel
      }
      .buttonStyle(.plain)
      .padding(.horizontal, 8)
      .padding(.vertical, 4)
      .background(
        RoundedRectangle(cornerRadius: 5, style: .continuous)
          .fill(Color(nsColor: .controlBackgroundColor))
      )
      .overlay(
        RoundedRectangle(cornerRadius: 5, style: .continuous)
          .strokeBorder(Color.primary.opacity(0.15), lineWidth: 0.5)
      )
      .disabled(isDisabled)
      .opacity(isDisabled ? 0.5 : 1)
      .popover(isPresented: $isPopoverPresented, arrowEdge: .bottom) {
        ThemePickerPopover(
          options: options,
          previews: previews,
          selection: selection,
          onPick: { picked in
            onPick(picked)
            isPopoverPresented = false
          }
        )
      }
    }
  }

  /// Mimics the macOS popup-button look: inline swatch + theme name +
  /// trailing chevron. Shows a "Select Theme" placeholder when nothing
  /// is currently selected.
  @ViewBuilder
  private var triggerLabel: some View {
    HStack(spacing: 8) {
      if let selection {
        ThemeSwatchStrip(preview: previews[selection], dotSize: 9)
        Text(selection)
          .foregroundStyle(.primary)
          .lineLimit(1)
      } else {
        Text("Select Theme")
          .foregroundStyle(.secondary)
      }
      Spacer(minLength: 8)
      Image(systemName: "chevron.up.chevron.down")
        .font(.system(size: 9, weight: .semibold))
        .foregroundStyle(.secondary)
        .accessibilityHidden(true)
    }
    .frame(minWidth: 220, maxWidth: 320, alignment: .leading)
    .contentShape(Rectangle())
  }
}

/// Popover body: a List of themes on the left, a live `ThemePreviewCard` on
/// the right driven by hover (with selection as a fallback when nothing is
/// hovered yet).
private struct ThemePickerPopover: View {
  let options: [String]
  let previews: [String: GhosttyThemePreview]
  let selection: String?
  let onPick: (String?) -> Void

  @State private var hovered: String?

  /// Preview to show in the side card. Hover wins over selection so the
  /// pane responds to the cursor; falls back to the committed value on
  /// initial open so the user sees what's currently in effect.
  private var previewTarget: String? { hovered ?? selection }

  var body: some View {
    HStack(spacing: 0) {
      themeList
        .frame(width: 280)
      Divider()
      ThemePreviewCard(
        name: previewTarget,
        preview: previewTarget.flatMap { previews[$0] }
      )
      .frame(width: 240)
    }
    .frame(height: 360)
  }

  private var themeList: some View {
    ScrollViewReader { proxy in
      ScrollView {
        LazyVStack(spacing: 0) {
          ForEach(options, id: \.self) { name in
            ThemeListRow(
              name: name,
              preview: previews[name],
              isSelected: name == selection,
              isHovered: name == hovered
            )
            .id(name)
            .contentShape(Rectangle())
            .onHover { hovering in
              if hovering {
                hovered = name
              } else if hovered == name {
                hovered = nil
              }
            }
            .onTapGesture {
              onPick(name)
            }
            .accessibilityAddTraits(.isButton)
            .accessibilityLabel(name)
          }
        }
        .padding(.vertical, 4)
      }
      .onAppear {
        guard let selection else { return }
        // Defer to next runloop so the list has measured before we scroll.
        DispatchQueue.main.async {
          proxy.scrollTo(selection, anchor: .center)
        }
      }
    }
  }
}

private struct ThemeListRow: View {
  let name: String
  let preview: GhosttyThemePreview?
  let isSelected: Bool
  let isHovered: Bool

  var body: some View {
    HStack(spacing: 10) {
      ThemeSwatchStrip(preview: preview)
      Text(name)
        .lineLimit(1)
        .foregroundStyle(.primary)
      Spacer(minLength: 4)
      if isSelected {
        Image(systemName: "checkmark")
          .font(.system(size: 10, weight: .bold))
          .foregroundStyle(.secondary)
          .accessibilityLabel("Selected")
      }
    }
    .padding(.horizontal, 10)
    .padding(.vertical, 5)
    .background(rowBackground)
  }

  @ViewBuilder
  private var rowBackground: some View {
    if isHovered {
      RoundedRectangle(cornerRadius: 4, style: .continuous)
        .fill(Color.accentColor.opacity(0.18))
        .padding(.horizontal, 4)
    } else if isSelected {
      RoundedRectangle(cornerRadius: 4, style: .continuous)
        .fill(Color.primary.opacity(0.06))
        .padding(.horizontal, 4)
    } else {
      Color.clear
    }
  }
}

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
  @State private var isHovered = false

  var body: some View {
    LabeledContent(title) {
      Button {
        isPopoverPresented = true
      } label: {
        triggerLabel
      }
      .buttonStyle(.plain)
      .disabled(isDisabled)
      .opacity(isDisabled ? 0.5 : 1)
      .onHover { hovering in
        isHovered = hovering && !isDisabled
      }
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

  /// Mirrors the system `.menu` Picker inside `Form(.grouped)`: no resting
  /// background, a faint highlight on hover, and a permanent accent-tinted
  /// chevron badge on the trailing edge (matching AppKit's `NSPopUpButton`).
  @ViewBuilder
  private var triggerLabel: some View {
    HStack(spacing: 6) {
      if let selection {
        ThemeSwatchStrip(preview: previews[selection], dotSize: 9)
        Text(selection)
          .foregroundStyle(.primary)
          .lineLimit(1)
      } else {
        Text("Select Theme")
          .foregroundStyle(.secondary)
      }
      chevronBadge
    }
    .padding(.horizontal, 10)
    .padding(.vertical, 5)
    .background(
      RoundedRectangle(cornerRadius: 6, style: .continuous)
        .fill(isHovered ? Self.tintFill : Color.clear)
    )
    .contentShape(Rectangle())
  }

  /// Circular badge holding the up/down chevron. Always tinted with the
  /// same fill as the hover highlight so the popup-arrow reads as part of
  /// the same affordance the cursor lights up.
  private var chevronBadge: some View {
    Image(systemName: "chevron.up.chevron.down")
      .font(.system(size: 9, weight: .bold))
      .foregroundStyle(.secondary)
      .frame(width: 18, height: 18)
      .background(Circle().fill(Self.tintFill))
      .accessibilityHidden(true)
  }

  private static let tintFill = Color.primary.opacity(0.08)
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

import SwiftUI

/// Font-family picker mirroring `ThemePickerButton`: a popup-styled trigger that
/// opens a popover with a scrollable family list on the left and a live preview
/// of the hovered / selected family on the right. We avoid a stock `.menu`
/// Picker because macOS strips custom content (per-family rendering, hover
/// preview) from menu items.
struct FontPickerButton: View {
  let title: String
  /// Family names to list, already including the user's current value if it
  /// isn't installed. A leading "Default" row is added by the popover.
  let families: [String]
  /// Subset of `families` carrying the monospace trait; badged in the list.
  let monospaced: Set<String>
  /// Currently selected family; `nil` means "Default" (Ghostty's own font).
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
        FontPickerPopover(
          families: families,
          monospaced: monospaced,
          selection: selection,
          onPick: { picked in
            onPick(picked)
            isPopoverPresented = false
          }
        )
      }
      .frame(maxHeight: .infinity, alignment: .center)
    }
  }

  /// Mirrors `ThemePickerButton`'s trigger: a faint hover highlight and a
  /// chevron badge, showing the selected family name.
  @ViewBuilder
  private var triggerLabel: some View {
    HStack(alignment: .center, spacing: 6) {
      if let selection {
        Text(selection)
          .foregroundStyle(.primary)
          .lineLimit(1)
      } else {
        Text("Default")
          .foregroundStyle(.secondary)
      }
      chevronBadge
    }
    .padding(.leading, 10)
    .padding(.trailing, 5)
    .padding(.vertical, 3)
    .background(
      RoundedRectangle(cornerRadius: 5, style: .continuous)
        .fill(isHovered ? Self.tintFill : Color.clear)
    )
    .contentShape(Rectangle())
  }

  private var chevronBadge: some View {
    Image(systemName: "chevron.up.chevron.down")
      .font(.system(size: 9, weight: .bold))
      .foregroundStyle(.secondary)
      .frame(width: 18, height: 18)
      .background(Circle().fill(isHovered ? Color.clear : Self.tintFill))
      .accessibilityHidden(true)
  }

  private static let tintFill = Color.primary.opacity(0.08)
}

/// A row identity in the family list: the "Default" sentinel plus one case per
/// installed family. Hashable so it can drive `ForEach` ids and hover state.
private enum FontChoice: Hashable {
  case systemDefault
  case family(String)

  /// The config value this choice maps to (`nil` for Default).
  var familyName: String? {
    if case .family(let name) = self { return name }
    return nil
  }
}

/// Popover body: a List of families on the left, a live `FontPreviewCard` on
/// the right driven by hover (falling back to the selection).
private struct FontPickerPopover: View {
  let families: [String]
  let monospaced: Set<String>
  let selection: String?
  let onPick: (String?) -> Void

  @State private var hovered: FontChoice?

  private var selectedChoice: FontChoice {
    selection.map(FontChoice.family) ?? .systemDefault
  }

  /// Hover wins over selection so the preview tracks the cursor; falls back to
  /// the committed value when nothing is hovered.
  private var previewTarget: FontChoice {
    hovered ?? selectedChoice
  }

  var body: some View {
    HStack(spacing: 0) {
      familyList
        .frame(width: 260)
      Divider()
      FontPreviewCard(choice: previewTarget, monospaced: monospaced)
        .frame(width: 260)
    }
    .frame(height: 360)
  }

  private var familyList: some View {
    ScrollViewReader { proxy in
      ScrollView {
        LazyVStack(spacing: 0) {
          row(for: .systemDefault)
          ForEach(families, id: \.self) { name in
            row(for: .family(name))
          }
        }
        .padding(.vertical, 4)
      }
      .onAppear {
        // Defer to next runloop so the list has measured before we scroll.
        DispatchQueue.main.async {
          proxy.scrollTo(selectedChoice, anchor: .center)
        }
      }
    }
  }

  @ViewBuilder
  private func row(for choice: FontChoice) -> some View {
    FontListRow(
      choice: choice,
      isMonospaced: choice.familyName.map(monospaced.contains) ?? false,
      isSelected: choice == selectedChoice,
      isHovered: choice == hovered
    )
    .id(choice)
    .contentShape(Rectangle())
    .onHover { hovering in
      if hovering {
        hovered = choice
      } else if hovered == choice {
        hovered = nil
      }
    }
    .onTapGesture {
      onPick(choice.familyName)
    }
    .accessibilityAddTraits(.isButton)
    .accessibilityLabel(choice.familyName ?? "Default")
  }
}

private struct FontListRow: View {
  let choice: FontChoice
  let isMonospaced: Bool
  let isSelected: Bool
  let isHovered: Bool

  var body: some View {
    HStack(spacing: 8) {
      // Fixed-width leading slot keeps family names aligned whether or not the
      // row carries a monospace badge.
      monospaceBadge
        .frame(width: 14, alignment: .center)
      Text(displayName)
        .font(rowFont)
        .lineLimit(1)
        .truncationMode(.tail)
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
  private var monospaceBadge: some View {
    if isMonospaced {
      Image(systemName: "chevron.left.forwardslash.chevron.right")
        .font(.caption2)
        .foregroundStyle(.secondary)
        .accessibilityLabel("Monospaced")
    } else {
      Color.clear
    }
  }

  private var displayName: String {
    choice.familyName ?? "Default"
  }

  /// Render each family in its own face so the list doubles as a preview;
  /// "Default" uses the system font.
  private var rowFont: Font {
    choice.familyName.map { .custom($0, size: 13) } ?? .system(size: 13)
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

/// Side panel showing a larger live sample of the hovered / selected family:
/// a big glyph pair plus alphabet, digits, and code-ish symbols rendered in
/// the font so the differences (and monospacing) are visible at a glance.
private struct FontPreviewCard: View {
  let choice: FontChoice
  let monospaced: Set<String>

  private var fontName: String? { choice.familyName }
  private var isMonospaced: Bool { fontName.map(monospaced.contains) ?? false }

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      header
      terminalSample
      Spacer(minLength: 0)
    }
    .padding(12)
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    .background(Color(nsColor: .windowBackgroundColor))
  }

  private var header: some View {
    HStack(spacing: 6) {
      Text(fontName ?? "System Default")
        .font(.callout.weight(.medium))
        .lineLimit(2)
      if isMonospaced {
        Image(systemName: "chevron.left.forwardslash.chevron.right")
          .font(.caption2)
          .foregroundStyle(.secondary)
          .accessibilityLabel("Monospaced")
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }

  /// Mock terminal mirroring `ThemePreviewCard`'s sample lines, but rendered in
  /// the previewed font so you can judge it against real terminal output. Colors
  /// are a fixed neutral dark scheme since a font carries none of its own.
  private var terminalSample: some View {
    let fg = Color(white: 0.92)
    let cursor = fg.opacity(0.8)
    let green = Color(red: 0.40, green: 0.78, blue: 0.42)
    let red = Color(red: 0.91, green: 0.45, blue: 0.45)

    return VStack(alignment: .leading, spacing: 4) {
      HStack(spacing: 4) {
        Text("$")
          .foregroundStyle(fg.opacity(0.7))
        Text("git status")
          .foregroundStyle(fg)
        RoundedRectangle(cornerRadius: 1)
          .fill(cursor)
          .frame(width: 6, height: 12)
      }
      Text("On branch main")
        .foregroundStyle(fg.opacity(0.85))
      Text("error: 1 file modified")
        .foregroundStyle(red)
      Text("✓ ready to commit")
        .foregroundStyle(green)
    }
    .font(previewFont(12))
    .lineLimit(1)
    .minimumScaleFactor(0.7)
    .padding(10)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(Color(white: 0.13), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
    .overlay(
      RoundedRectangle(cornerRadius: 6, style: .continuous)
        .strokeBorder(Color.primary.opacity(0.12), lineWidth: 0.5)
    )
  }

  private func previewFont(_ size: CGFloat) -> Font {
    fontName.map { .custom($0, size: size) } ?? .system(size: size)
  }
}

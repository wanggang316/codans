import SwiftUI

/// Compact 6-dot color strip summarizing a Ghostty theme — background,
/// foreground, then ANSI red/green/yellow/blue from the palette. Sized to
/// fit inline in a picker row or a popover list row. Unknown / unparseable
/// slots fall through to a neutral dashed placeholder so a missing palette
/// entry is visually distinct from an actual color.
struct ThemeSwatchStrip: View {
  let preview: GhosttyThemePreview?
  /// Edge length of each square. Default tuned for popover list rows.
  var dotSize: CGFloat = 10
  var spacing: CGFloat = 2

  var body: some View {
    HStack(spacing: spacing) {
      ForEach(Array(strip.enumerated()), id: \.offset) { _, rgb in
        ThemeSwatchDot(rgb: rgb, size: dotSize)
      }
    }
    .accessibilityHidden(true)
  }

  private var strip: [GhosttyThemePreview.RGB?] {
    preview?.swatchStrip ?? Array(repeating: nil, count: 6)
  }
}

/// Single color square. Renders a neutral placeholder when `rgb` is nil so
/// callers can render a fixed-width strip regardless of catalog completeness.
struct ThemeSwatchDot: View {
  let rgb: GhosttyThemePreview.RGB?
  var size: CGFloat = 10

  var body: some View {
    RoundedRectangle(cornerRadius: 2, style: .continuous)
      .fill(rgb.map { Color(red: $0.r, green: $0.g, blue: $0.b) } ?? Color.gray.opacity(0.18))
      .overlay(
        RoundedRectangle(cornerRadius: 2, style: .continuous)
          .strokeBorder(Color.primary.opacity(0.12), lineWidth: 0.5)
      )
      .frame(width: size, height: size)
  }
}

/// Larger hover/selection preview for the popover side panel. Shows a mini
/// "terminal sample" using foreground/background plus the full 16-entry ANSI
/// palette laid out as two rows of eight dots. Falls back to a placeholder
/// message when no preview is available.
struct ThemePreviewCard: View {
  let name: String?
  let preview: GhosttyThemePreview?

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      if let name {
        Text(name)
          .font(.callout.weight(.medium))
          .lineLimit(2)
          .frame(maxWidth: .infinity, alignment: .leading)
      } else {
        Text("Hover a theme")
          .font(.callout)
          .foregroundStyle(.secondary)
      }
      sampleCard
      paletteGrid
      Spacer(minLength: 0)
    }
    .padding(12)
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    .background(Color(nsColor: .windowBackgroundColor))
  }

  /// Minimal "terminal" mock: foreground text on background, plus a cursor
  /// block tinted by `cursor-color`. The sample line uses static text so
  /// width never reflows between themes.
  @ViewBuilder
  private var sampleCard: some View {
    let bg = preview?.background.map { Color(red: $0.r, green: $0.g, blue: $0.b) } ?? Color.gray.opacity(0.2)
    let fg = preview?.foreground.map { Color(red: $0.r, green: $0.g, blue: $0.b) } ?? Color.primary
    let cursor =
      preview?.cursor.map { Color(red: $0.r, green: $0.g, blue: $0.b) } ?? fg.opacity(0.6)

    VStack(alignment: .leading, spacing: 4) {
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
      if let red = preview?.palette[1] {
        Text("error: 1 file modified")
          .foregroundStyle(Color(red: red.r, green: red.g, blue: red.b))
      }
      if let green = preview?.palette[2] {
        Text("✓ ready to commit")
          .foregroundStyle(Color(red: green.r, green: green.g, blue: green.b))
      }
    }
    .font(.system(.caption, design: .monospaced))
    .padding(8)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(bg, in: RoundedRectangle(cornerRadius: 4, style: .continuous))
    .overlay(
      RoundedRectangle(cornerRadius: 4, style: .continuous)
        .strokeBorder(Color.primary.opacity(0.12), lineWidth: 0.5)
    )
  }

  /// 16 ANSI palette dots in two rows of eight (normal + bright).
  private var paletteGrid: some View {
    VStack(alignment: .leading, spacing: 3) {
      paletteRow(range: 0...7)
      paletteRow(range: 8...15)
    }
  }

  private func paletteRow(range: ClosedRange<Int>) -> some View {
    HStack(spacing: 3) {
      ForEach(Array(range), id: \.self) { idx in
        ThemeSwatchDot(rgb: preview?.palette[idx], size: 14)
      }
    }
  }
}

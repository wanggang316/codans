import SwiftUI
import CodansCore

/// Split-button for the Merge action. Primary face merges with the current default
/// strategy; the caret half opens a Menu with the three strategies plus a "Set as default
/// for this Project" sub-menu (per UI design Surface 2).
///
/// Layout is a `.borderedProminent` primary `Button` (accent-blue capsule) plus a
/// self-drawn caret, both wrapped in a single `Capsule(style: .continuous)`
/// stroke so the chevron area shares one frame with the Merge half. The outer
/// `Capsule` matches the inner pill's curvature on macOS 26; the sibling Close /
/// Mark-ready / Rerun-failed buttons in `PullRequestPopover` draw their own grey
/// capsule at matching metrics so the whole action row reads as uniformly-shaped
/// capsules — only the colour distinguishes primary from secondary actions.
struct MergeSplitButton: View {
  let defaultStrategy: MergeStrategy
  let isDisabled: Bool
  let disabledReason: String?
  let onMerge: (MergeStrategy) -> Void
  let onSetProjectDefault: (MergeStrategy) -> Void

  var body: some View {
    HStack(spacing: 0) {
      Button {
        onMerge(defaultStrategy)
      } label: {
        Text("Merge (\(defaultStrategy.shortName))")
          .font(.callout)
          .padding(.horizontal, 10)
      }
      .buttonStyle(.borderedProminent)
      .disabled(isDisabled)
      .help(isDisabled ? (disabledReason ?? "") : "Merge with \(defaultStrategy.displayName)")

      // Self-drawn caret with a clear-label Menu overlaid as the click target.
      // The borderless-button menu style renders its label through AppKit, so
      // inside the sidebar-anchored popover the glyph's colour is outside
      // SwiftUI's control (`foregroundStyle` on the label is ignored) and the
      // disabled dimming erased it entirely on dark backgrounds. Drawing the
      // glyph ourselves keeps it `.primary`-adaptive in both schemes and lets
      // the disabled state dim without vanishing; the transparent Menu on top
      // still opens the strategy menu.
      Image(systemName: "chevron.down")
        .imageScale(.small)
        .foregroundStyle(.primary)
        .opacity(isDisabled ? 0.35 : 1)
        .padding(.horizontal, 6)
        .accessibilityHidden(true)
        .overlay {
          Menu {
            ForEach(MergeStrategy.allCases, id: \.self) { strategy in
              Button(strategy.displayName) { onMerge(strategy) }
            }
            Divider()
            Menu("Set as default for this Project") {
              ForEach(MergeStrategy.allCases, id: \.self) { strategy in
                Button(strategy.displayName) { onSetProjectDefault(strategy) }
              }
            }
          } label: {
            Color.clear
          }
          .menuStyle(.borderlessButton)
          .menuIndicator(.hidden)
          .disabled(isDisabled)
        }
        .fixedSize()
    }
    .background(
      // Matches the corner radius of macOS 26's `.borderedProminent`
      // capsule at `.controlSize(.regular)` — using `Capsule()` here
      // gives a height/2 radius that's visibly rounder than the inner
      // Merge pill.
      RoundedRectangle(cornerRadius: 8, style: .continuous)
        .stroke(Color.secondary.opacity(0.3), lineWidth: 0.5)
    )
  }
}

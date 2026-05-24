import ComposableArchitecture
import SwiftUI

/// Inline error banner shown under the worktree header when a branch
/// switch failed. Reads its single source of truth from
/// `BranchSwitcherFeature.State.switchError`; tapping the dismiss button
/// sends `.errorDismissed` to clear it.
///
/// Hosted by `WorktreeDetailView` (T10), NOT embedded inside the popover —
/// the popover dismisses before the switch effect resolves, so the banner
/// is the only persistent surface for git's stderr first-line.
struct BranchSwitcherErrorBannerView: View {
  let store: StoreOf<BranchSwitcherFeature>

  var body: some View {
    if case .message(let text) = store.switchError {
      HStack(spacing: 8) {
        Image(systemName: "exclamationmark.triangle.fill")
          .foregroundStyle(.orange)
          .font(.callout)
          .accessibilityHidden(true)

        Text(text)
          .font(.callout)
          .foregroundStyle(.primary)
          .lineLimit(2)
          .truncationMode(.tail)
          .textSelection(.enabled)

        Spacer(minLength: 8)

        Button {
          store.send(.errorDismissed)
        } label: {
          Image(systemName: "xmark")
            .font(.caption)
            .padding(4)
            .contentShape(.rect)
        }
        .buttonStyle(.borderless)
        .accessibilityLabel("Dismiss branch switch error")
        .accessibilityIdentifier("branch_switcher.error_dismiss_button")
      }
      .padding(.horizontal, 12)
      .padding(.vertical, 8)
      .background(Color.orange.opacity(0.10))
      .overlay(alignment: .bottom) {
        Divider()
      }
      .transition(.opacity.combined(with: .move(edge: .top)))
      .animation(.easeInOut(duration: 0.18), value: store.switchError)
      .accessibilityIdentifier("branch_switcher.error_banner")
      .accessibilityElement(children: .combine)
      .accessibilityLabel("Branch switch error: \(text)")
      .accessibilityAddTraits(.isStaticText)
    }
  }
}

#Preview("error") {
  BranchSwitcherErrorBannerView(
    store: Store(
      initialState: BranchSwitcherFeature.State(
        switchError: .message(
          "error: Your local changes to the following files would be overwritten"
        )
      ),
      reducer: { BranchSwitcherFeature() }
    )
  )
  .frame(width: 600)
  .padding()
}

#Preview("no error") {
  BranchSwitcherErrorBannerView(
    store: Store(
      initialState: BranchSwitcherFeature.State(),
      reducer: { BranchSwitcherFeature() }
    )
  )
  .frame(width: 600)
  .padding()
}

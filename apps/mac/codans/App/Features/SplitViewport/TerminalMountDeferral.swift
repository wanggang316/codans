import CodansCore
import SwiftUI

/// Holds back the terminal of the Tab selected because the shown Tab of
/// this Pane was just closed, until the strip's close animation has played.
/// A terminal surface entering the window stalls compositing for a few
/// frames; landing mid-animation it freezes the strip, landing after it the
/// stall is invisible. Only the content slot of the one Pane waits: its
/// strip and every other Pane stay on screen. Plain Tab switches mount at
/// once, because nothing animates then.
struct TerminalMountDeferral<Content: View>: View {
  /// The Pane's selected Content.
  let activeContentID: ContentID?
  /// Contents of the Pane's Tabs.
  let contentIDs: [ContentID]
  @ViewBuilder let content: Content

  /// Content whose terminal is mounted.
  @State private var mountedContentID: ContentID?

  var body: some View {
    Group {
      if isDeferring {
        let terminalBackground = GhosttyRuntime.shared?.backgroundColor() ?? .underPageBackgroundColor
        Color(nsColor: terminalBackground)
      } else {
        content
      }
    }
    .task(id: activeContentID) {
      if isDeferring {
        try? await Task.sleep(for: TabBarMetrics.firstPaneDelay)
        guard !Task.isCancelled else { return }
      }
      mountedContentID = activeContentID
    }
  }

  /// The mounted Content left the Pane and another one took over the
  /// selection.
  private var isDeferring: Bool {
    guard let mountedContentID, mountedContentID != activeContentID else { return false }
    return !contentIDs.contains(mountedContentID)
  }
}

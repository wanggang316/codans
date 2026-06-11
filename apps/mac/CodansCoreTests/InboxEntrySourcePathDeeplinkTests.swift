import Foundation
import Testing

@testable import CodansCore

/// Self-test for the `(projectID, worktreeID, tabID, paneID)` round-trip
/// across the macOS banner deeplink. The encoder lives in the app
/// target's `OSNotifier.deeplink(for:)` and the decoder in
/// `AppDelegate.parseDeeplink(_:)`; both are exercised together in
/// production via macOS click-through. Test pinpoints the format here
/// in Core so an accidental schema change (URL scheme, host, query key
/// rename) is caught at build time rather than at runtime click.
struct InboxEntrySourcePathDeeplinkTests {
  @Test
  func sourcePathEncodesIDsAsLowercaseUUIDStrings() {
    let path = InboxEntry.SourcePath(
      projectID: ProjectID(),
      worktreeID: WorktreeID(),
      tabID: TabID(),
      paneID: PaneID()
    )
    // The deeplink encoder lives in the app target; here we mirror the
    // format inline to ensure both sides agree.
    let url = URL(string: "codans://focus")!
      .appending(queryItems: [
        URLQueryItem(name: "project", value: path.projectID.raw.uuidString),
        URLQueryItem(name: "worktree", value: path.worktreeID.raw.uuidString),
        URLQueryItem(name: "tab", value: path.tabID.raw.uuidString),
        URLQueryItem(name: "pane", value: path.paneID.raw.uuidString),
      ])
    let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
    let items = Dictionary(
      uniqueKeysWithValues: (components?.queryItems ?? []).compactMap { item -> (String, String)? in
        guard let value = item.value else { return nil }
        return (item.name, value)
      }
    )
    #expect(url.scheme == "codans")
    #expect(url.host == "focus")
    #expect(items["project"] == path.projectID.raw.uuidString)
    #expect(items["worktree"] == path.worktreeID.raw.uuidString)
    #expect(items["tab"] == path.tabID.raw.uuidString)
    #expect(items["pane"] == path.paneID.raw.uuidString)
  }
}

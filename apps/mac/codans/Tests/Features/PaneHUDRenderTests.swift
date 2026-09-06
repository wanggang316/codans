import AppKit
import CodansCore
import Foundation
import SwiftUI
import Testing

@testable import Codans

/// Offscreen renders of the pane HUD, for checking its geometry without a
/// window. Writes PNGs only when `PANE_HUD_RENDER_DIR` is set; otherwise
/// the render still has to succeed, which is the assertion.
@MainActor
struct PaneHUDRenderTests {
  private static func makeManager(queued: Int) -> (HierarchyManager, PaneID) {
    let paneID = PaneID()
    let pane = Pane(
      id: paneID,
      workingDirectory: "/tmp/w",
      agentKind: .claudeCode,
      commandQueue: (0..<queued).map { QueuedCommand(text: "cmd \($0)", timing: .afterCurrentTask) }
    )
    let tab = Tab(splitTree: SplitTree(leaf: paneID), panes: [pane])
    let worktree = Worktree(name: "w", path: "/tmp/w", branch: "main", tabs: [tab])
    let project = Project(name: "p", rootPath: "/tmp", worktrees: [worktree])
    let tempURL = FileManager.default.temporaryDirectory
      .appending(component: UUID().uuidString + ".json")
    let manager = HierarchyManager(
      catalog: Catalog(projects: [project]),
      store: CatalogStore(fileURL: tempURL),
      runtime: FakeHierarchyRuntime()
    )
    return (manager, paneID)
  }

  /// The HUD as `LazyPaneHost` mounts it: top-trailing over a dark surface.
  private static func render(
    manager: HierarchyManager, paneID: PaneID, expanded: Bool
  ) -> CGImage? {
    let content = ZStack(alignment: .topTrailing) {
      Color(red: 0.12, green: 0.12, blue: 0.12)
      PaneHUDView(paneID: paneID, expanded: expanded)
        .padding(.top, 4)
        .padding(.trailing, 4)
    }
    .frame(width: 320, height: 160)
    .environment(manager)
    .environment(\.colorScheme, .dark)
    let renderer = ImageRenderer(content: content)
    renderer.scale = 2
    return renderer.cgImage
  }

  private static func write(_ image: CGImage, name: String) throws {
    guard let dir = ProcessInfo.processInfo.environment["PANE_HUD_RENDER_DIR"] else { return }
    let rep = NSBitmapImageRep(cgImage: image)
    let data = try #require(rep.representation(using: .png, properties: [:]))
    try data.write(to: URL(fileURLWithPath: dir).appending(component: name))
  }

  @Test
  func rendersCollapsedAndExpanded() throws {
    let (manager, paneID) = Self.makeManager(queued: 2)
    let collapsed = try #require(Self.render(manager: manager, paneID: paneID, expanded: false))
    let expanded = try #require(Self.render(manager: manager, paneID: paneID, expanded: true))
    try Self.write(collapsed, name: "hud-collapsed.png")
    try Self.write(expanded, name: "hud-expanded.png")
    #expect(collapsed.width == 640)
    #expect(expanded.width == 640)
  }
}

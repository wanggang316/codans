import AppKit
import CodansCore
import Foundation
import SwiftUI
import Testing

@testable import Codans

@MainActor
struct WorktreeProcessPresentationTests {
  @Test(arguments: [1, 3, 8])
  func changingEntriesPreservesPopoverSize(visibleRows: Int) {
    for scheme in [ColorScheme.light, .dark] {
      let entries = Self.entries(count: 12)
      let host = Self.host(
        entries: Array(entries.prefix(3)), visibleRows: visibleRows, scheme: scheme)
      let initialSize = Self.measure(host)
      #expect(abs(initialSize.width - 370) < 0.5)
      #expect(initialSize.height > CGFloat(visibleRows) * 34)

      // Exercise the same hosting view, as a presented popover receives
      // live updates while its opening-time row budget remains fixed.
      for count in [12, 1, 0, 5, 0] {
        host.rootView = Self.content(
          entries: Array(entries.prefix(count)), visibleRows: visibleRows, scheme: scheme
        )
        let updatedSize = Self.measure(host)
        #expect(abs(updatedSize.width - initialSize.width) < 0.5)
        #expect(abs(updatedSize.height - initialSize.height) < 0.5)
      }
    }
  }

  @Test
  func longNamesAndLargePIDsDoNotExpandPopover() {
    for scheme in [ColorScheme.light, .dark] {
      let host = Self.host(entries: Self.entries(count: 1), visibleRows: 3, scheme: scheme)
      let initialSize = Self.measure(host)
      host.rootView = Self.content(
        entries: Self.entries(count: 12, longNames: true), visibleRows: 3, scheme: scheme
      )
      let updatedSize = Self.measure(host)
      #expect(abs(updatedSize.width - 370) < 0.5)
      #expect(abs(updatedSize.height - initialSize.height) < 0.5)
    }
  }

  @Test
  func exportPresentationWhenRequested() throws {
    guard let directory = ProcessInfo.processInfo.environment["HAN130_RENDER_DIR"],
      !directory.isEmpty
    else { return }
    let destination = URL(fileURLWithPath: directory, isDirectory: true)
    try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
    for scheme in [ColorScheme.light, .dark] {
      for empty in [false, true] {
        let host = Self.host(
          entries: empty ? [] : Self.entries(count: 5, longNames: true),
          visibleRows: 3, scheme: scheme
        )
        _ = Self.measure(host)
        host.displayIfNeeded()
        let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        let png = try #require(bitmap.representation(using: .png, properties: [:]))
        let theme = scheme == .dark ? "dark" : "light"
        let state = empty ? "empty" : "populated"
        try png.write(to: destination.appendingPathComponent("processes-\(theme)-\(state).png"))
      }
    }
  }

  private static func content(
    entries: [WorktreeProcessEntry], visibleRows: Int, scheme: ColorScheme
  ) -> AnyView {
    AnyView(
      WorktreeProcessListView(entries: entries, visibleRows: visibleRows, onSelect: { _ in })
        .background(Color(nsColor: .windowBackgroundColor))
        .environment(\.colorScheme, scheme)
    )
  }

  private static func host(
    entries: [WorktreeProcessEntry], visibleRows: Int, scheme: ColorScheme
  ) -> NSHostingView<AnyView> {
    let host = NSHostingView(
      rootView: content(entries: entries, visibleRows: visibleRows, scheme: scheme))
    host.appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)
    return host
  }

  private static func measure(_ host: NSHostingView<AnyView>) -> NSSize {
    host.invalidateIntrinsicContentSize()
    host.needsLayout = true
    host.layoutSubtreeIfNeeded()
    let size = host.fittingSize
    host.setFrameSize(size)
    host.layoutSubtreeIfNeeded()
    return size
  }

  private static func entries(count: Int, longNames: Bool = false) -> [WorktreeProcessEntry] {
    let now = Date.now
    return (0..<count).map { index -> WorktreeProcessEntry in
      let name =
        longNames
        ? "Production validation / " + String(repeating: "very-long-command-name-", count: 12)
        : "Development server \(index + 1)"
      let pid: Int32 = longNames ? Int32.max - Int32(index) : 1234 + Int32(index)
      let startedAt = now.addingTimeInterval(-Double(75 + index * 3600))
      return WorktreeProcessEntry(
        paneID: PaneID(), projectID: ProjectID(), worktreeID: WorktreeID(), tabID: TabID(),
        name: name,
        kind: index == 0 ? .agent : .run,
        pid: pid,
        startedAt: startedAt,
        observedAt: now, workingDirectory: "/tmp/han-130",
        processName: ["node", "npm run tauri dev", "python3.13", "cargo", "handbox"][index % 5],
        agentKind: index == 0 ? .codex : nil
      )
    }
  }
}

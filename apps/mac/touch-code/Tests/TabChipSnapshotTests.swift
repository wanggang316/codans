import AppKit
import Foundation
import SnapshotTesting
import SwiftUI
import Testing
import TouchCodeCore

@testable import TouchCode

/// Visual regression coverage for the Tab-bar chip visuals landed in M1-T1.3.
/// Five cases exercise the chip background's state combinations plus one
/// row-level case proves the divider is suppressed adjacent to the active
/// chip.
///
/// The TabChipView itself owns hover/press as `@State`, which a plain render
/// cannot flip. These tests therefore snapshot `TabChipBackground` directly
/// for the state matrix; label + close-button visuals are covered by the
/// active-chip + row composites. M3 adds a dirty-state case once the writer
/// path lands.
///
/// Gated behind `TC_RUN_SNAPSHOT_TESTS=1` + `recordMode=false` — matches
/// `GitViewerSnapshotTests`'s convention. Running this suite without
/// reference PNGs intentionally fails the first pass so the record step is
/// explicit rather than accidental.
@MainActor
struct TabChipSnapshotTests {
  nonisolated static let snapshotsEnabled: Bool = {
    ProcessInfo.processInfo.environment["TC_RUN_SNAPSHOT_TESTS"] == "1"
  }()

  /// Flip to `true` for a record pass; flip back before commit.
  /// `assertSnapshot` takes the value as its `record:` parameter so the
  /// decision is per-call and local.
  nonisolated static let recordMode: Bool = false

  /// One chip at its exact runtime footprint — matches `TabBarMetrics`.
  @MainActor static let chipSize = CGSize(
    width: TabBarMetrics.chipMinWidth,
    height: TabBarMetrics.chipHeight
  )

  /// Bar row footprint — three chips plus an interior divider.
  @MainActor static let rowSize = CGSize(
    width: TabBarMetrics.chipMinWidth * 3 + TabBarMetrics.dividerWidth,
    height: TabBarMetrics.barHeight
  )

  // MARK: - Background state matrix

  @Test(.enabled(if: TabChipSnapshotTests.snapshotsEnabled))
  func idleBackground() {
    let host = Self.makeBackground(isActive: false, isHovering: false, isPressing: false)
    assertSnapshot(of: host, as: .image, record: Self.recordMode ? .all : nil)
  }

  @Test(.enabled(if: TabChipSnapshotTests.snapshotsEnabled))
  func hoverBackground() {
    let host = Self.makeBackground(isActive: false, isHovering: true, isPressing: false)
    assertSnapshot(of: host, as: .image, record: Self.recordMode ? .all : nil)
  }

  @Test(.enabled(if: TabChipSnapshotTests.snapshotsEnabled))
  func pressBackground() {
    let host = Self.makeBackground(isActive: false, isHovering: false, isPressing: true)
    assertSnapshot(of: host, as: .image, record: Self.recordMode ? .all : nil)
  }

  @Test(.enabled(if: TabChipSnapshotTests.snapshotsEnabled))
  func activeBackground() {
    let host = Self.makeBackground(isActive: true, isHovering: false, isPressing: false)
    assertSnapshot(of: host, as: .image, record: Self.recordMode ? .all : nil)
  }

  @Test(.enabled(if: TabChipSnapshotTests.snapshotsEnabled))
  func activeHoverBackground() {
    let host = Self.makeBackground(isActive: true, isHovering: true, isPressing: false)
    assertSnapshot(of: host, as: .image, record: Self.recordMode ? .all : nil)
  }

  // MARK: - Row composition

  @Test(.enabled(if: TabChipSnapshotTests.snapshotsEnabled))
  func rowOfThreeChipsWithMiddleActive() {
    // Second tab active — dividers should disappear on its left and right.
    let ids = [TabID(), TabID(), TabID()]
    let tabs: [TouchCodeCore.Tab] = [
      .init(id: ids[0], name: "main"),
      .init(id: ids[1], name: "feature/login"),
      .init(id: ids[2], name: "fix/crash"),
    ]

    let view = TabBarRowView(
      tabs: tabs,
      activeTabID: ids[1],
      onSelect: { _ in },
      onClose: { _ in },
      onMiddleClick: { _ in },
      onCloseOthers: { _ in },
      onCloseToRight: { _ in },
      onCloseAll: {},
      onRenameRequested: { _ in },
      onReorder: { _ in }
    )
    .frame(width: Self.rowSize.width, height: Self.rowSize.height, alignment: .bottom)
    .background(Color(nsColor: .windowBackgroundColor))

    let hosting = NSHostingView(rootView: view)
    hosting.frame = CGRect(origin: .zero, size: Self.rowSize)
    hosting.layoutSubtreeIfNeeded()
    assertSnapshot(of: hosting, as: .image, record: Self.recordMode ? .all : nil)
  }

  // MARK: - Helpers

  @MainActor
  static func makeBackground(
    isActive: Bool,
    isHovering: Bool,
    isPressing: Bool
  ) -> NSHostingView<some View> {
    let view = TabChipBackground(
      isActive: isActive,
      isHovering: isHovering,
      isPressing: isPressing
    )
    .frame(width: chipSize.width, height: chipSize.height, alignment: .bottom)
    .background(Color(nsColor: .windowBackgroundColor))

    let hosting = NSHostingView(rootView: view)
    hosting.frame = CGRect(origin: .zero, size: chipSize)
    hosting.layoutSubtreeIfNeeded()
    return hosting
  }
}

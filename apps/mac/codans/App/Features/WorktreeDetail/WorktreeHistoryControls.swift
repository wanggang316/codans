import AppKit
import CodansCore
import SwiftUI

/// One row of a Back / Forward segment's press-and-hold menu: an entry of
/// `RootFeature.State.navigationHistoryBack` / `...Forward` resolved against
/// the live catalog into the same identity the header's leading cluster
/// shows — Worktree glyph, branch, and a caption naming the Worktree and its
/// Project — plus the offset the jump action needs.
struct WorktreeHistoryEntry: Identifiable, Equatable {
  /// The leading glyph, chosen the way `WorktreeRowIcon` chooses it.
  enum Glyph: Equatable {
    case branch
    case defaultBranch
    case folder
    case pullRequest(PullRequestState, isDraft: Bool)
  }

  /// Distance from the top of its stack. `0` is the entry a single Back /
  /// Forward step lands on, which is also the entry's position in the menu
  /// once unresolvable ones have been dropped.
  let offset: Int
  let glyph: Glyph
  /// Row 1: the checked-out branch, as the header shows it.
  let branchTitle: String
  /// Row 2's leading part. Nil when the Worktree name restates the branch,
  /// the same suppression the header applies.
  let worktreeName: String?
  /// Row 2's trailing part, drawn in the Project's color when it has one.
  let projectName: String
  let projectColor: ProjectColor?

  var id: Int { offset }
}

extension WorktreeHistoryEntry {
  /// At most this many entries per menu. Deep stacks are navigable one step
  /// at a time; a menu longer than this stops being a shortcut.
  static let menuLimit = 15

  /// Resolves a history stack (oldest first, as the reducer stores it) into
  /// menu rows ordered nearest first. Entries whose Worktree has left the
  /// catalog are dropped — they would select nothing — while the offsets of
  /// the surviving ones stay true to the stack, so a jump still lands where
  /// the row says it does. `pullRequests` supplies the PR-state glyph, as
  /// it does for the header and sidebar.
  static func resolve(
    stack: [HierarchySelection],
    catalog: Catalog,
    pullRequests: [WorktreeID: PullRequestSnapshot] = [:]
  ) -> [WorktreeHistoryEntry] {
    var entries: [WorktreeHistoryEntry] = []
    for (offset, selection) in stack.reversed().enumerated() {
      guard
        let worktreeID = selection.worktreeID,
        let project = catalog.projects.first(where: { $0.id == selection.projectID }),
        let worktree = project.worktrees.first(where: { $0.id == worktreeID })
      else { continue }
      entries.append(
        WorktreeHistoryEntry(
          offset: offset,
          glyph: glyph(for: worktree, in: project, pullRequest: pullRequests[worktreeID]),
          branchTitle: worktree.branch ?? "(detached)",
          worktreeName: worktree.name == (worktree.branch ?? "") ? nil : worktree.name,
          projectName: project.name,
          projectColor: project.color
        )
      )
      if entries.count == menuLimit { break }
    }
    return entries
  }

  /// `WorktreeRowIcon`'s precedence: a folder-kind Project's synthetic row
  /// is a folder; otherwise a PR's state wins; otherwise the main checkout
  /// is a star and every other Worktree a branch.
  private static func glyph(
    for worktree: Worktree, in project: Project, pullRequest: PullRequestSnapshot?
  ) -> Glyph {
    let isMainCheckout = worktree.path == project.rootPath
    if isMainCheckout && project.gitRoot == nil { return .folder }
    if let pullRequest { return .pullRequest(pullRequest.state, isDraft: pullRequest.isDraft) }
    return isMainCheckout ? .defaultBranch : .branch
  }
}

/// The header's Back / Forward control: the `NSSegmentedControl` macOS apps
/// put in their toolbar for this (SwiftUI's own toolbar split buttons are
/// the same control). AppKit draws the divider, greys out the segment whose
/// stack is empty, fires the action on a click, and opens a segment's menu
/// on click-and-hold; the toolbar item supplies the glass capsule.
///
/// SwiftUI has no equivalent: `Menu(primaryAction:)` never opens on
/// click-and-hold (macOS 26), and a disabled `Button` is dropped from the
/// toolbar instead of dimmed.
struct WorktreeHistoryControls: NSViewRepresentable {
  /// Menu rows for each direction, nearest entry first.
  let back: [WorktreeHistoryEntry]
  let forward: [WorktreeHistoryEntry]
  let onJump: (WorktreeHistoryJump) -> Void

  enum Direction: Int, CaseIterable {
    case back = 0
    case forward = 1

    var title: String {
      switch self {
      case .back: return "Back"
      case .forward: return "Forward"
      }
    }

    /// The Go menu command this segment mirrors; its chord joins the tooltip.
    var commandID: CommandID {
      switch self {
      case .back: return .worktreeHistoryBack
      case .forward: return .worktreeHistoryForward
      }
    }

    var symbol: String {
      switch self {
      case .back: return "chevron.backward"
      case .forward: return "chevron.forward"
      }
    }

    func jump(offset: Int) -> WorktreeHistoryJump {
      switch self {
      case .back: return .back(offset: offset)
      case .forward: return .forward(offset: offset)
      }
    }
  }

  func makeCoordinator() -> Coordinator {
    Coordinator(onJump: onJump)
  }

  func makeNSView(context: Context) -> NSSegmentedControl {
    let images = Direction.allCases.map { direction in
      NSImage(systemSymbolName: direction.symbol, accessibilityDescription: direction.title)
        ?? NSImage()
    }
    let control = NSSegmentedControl(
      images: images,
      trackingMode: .momentary,
      target: context.coordinator,
      action: #selector(Coordinator.segmentClicked(_:))
    )
    // `.automatic` lets AppKit pick the toolbar rendering; equal segments
    // keep the divider on the middle.
    control.segmentStyle = .automatic
    control.segmentDistribution = .fillEqually
    control.setAccessibilityIdentifier("header.history")
    return control
  }

  func updateNSView(_ control: NSSegmentedControl, context: Context) {
    context.coordinator.onJump = onJump
    // Set on every update, not once in `makeNSView`, so a rebind in
    // Settings shows up without rebuilding the control.
    let shortcuts = context.environment.resolvedShortcuts
    for direction in Direction.allCases {
      control.setToolTip(
        ShortcutDisplay.tooltip(direction.title, for: direction.commandID, in: shortcuts),
        forSegment: direction.rawValue
      )
      let entries = entries(for: direction)
      control.setEnabled(!entries.isEmpty, forSegment: direction.rawValue)
      control.setMenu(
        menu(for: direction, entries: entries, coordinator: context.coordinator),
        forSegment: direction.rawValue
      )
    }
  }

  func sizeThatFits(
    _ proposal: ProposedViewSize,
    nsView: NSSegmentedControl,
    context: Context
  ) -> CGSize? {
    nsView.intrinsicContentSize
  }

  private func entries(for direction: Direction) -> [WorktreeHistoryEntry] {
    switch direction {
    case .back: return back
    case .forward: return forward
    }
  }

  /// The segment's press-and-hold list. Nil for an empty stack, so a segment
  /// with nowhere to go never opens an empty menu.
  private func menu(
    for direction: Direction,
    entries: [WorktreeHistoryEntry],
    coordinator: Coordinator
  ) -> NSMenu? {
    guard !entries.isEmpty else { return nil }
    let menu = NSMenu()
    for entry in entries {
      let item = NSMenuItem(
        title: entry.branchTitle,
        action: #selector(Coordinator.menuItemPicked(_:)),
        keyEquivalent: ""
      )
      item.attributedTitle = HistoryMenuRow.title(for: entry)
      item.image = HistoryMenuRow.image(for: entry.glyph)
      item.target = coordinator
      // Carries the stack offset, not the row index: unresolvable entries
      // are left out of the menu but still counted by the jump.
      item.representedObject = direction.jump(offset: entry.offset)
      menu.addItem(item)
    }
    return menu
  }

  @MainActor
  final class Coordinator: NSObject {
    var onJump: (WorktreeHistoryJump) -> Void

    init(onJump: @escaping (WorktreeHistoryJump) -> Void) {
      self.onJump = onJump
    }

    // Explicit (empty) deinit: the app target compiles with MainActor
    // default isolation, and a synthesized *isolated* deinit double-frees
    // when SwiftUI tears the owning view down mid-cascade.
    deinit {}

    @objc func segmentClicked(_ sender: NSSegmentedControl) {
      guard let direction = Direction(rawValue: sender.selectedSegment) else { return }
      onJump(direction.jump(offset: 0))
    }

    @objc func menuItemPicked(_ sender: NSMenuItem) {
      guard let jump = sender.representedObject as? WorktreeHistoryJump else { return }
      onJump(jump)
    }
  }
}

/// The header's identity cluster, rendered for an `NSMenuItem`: the
/// Worktree glyph in its role / PR tint, the branch in the header's bold
/// weight, and a caption row of Worktree name · Project with the Project
/// name in the Project's color.
@MainActor
private enum HistoryMenuRow {
  static func title(for entry: WorktreeHistoryEntry) -> NSAttributedString {
    let menuFont = NSFont.menuFont(ofSize: 0)
    let captionFont = NSFont.menuFont(ofSize: NSFont.smallSystemFontSize)
    let text = NSMutableAttributedString(
      string: entry.branchTitle,
      attributes: [.font: NSFont.systemFont(ofSize: menuFont.pointSize, weight: .semibold)]
    )
    let caption: [NSAttributedString.Key: Any] = [
      .font: captionFont, .foregroundColor: NSColor.secondaryLabelColor,
    ]
    text.append(NSAttributedString(string: "\n", attributes: caption))
    if let worktreeName = entry.worktreeName {
      text.append(NSAttributedString(string: "\(worktreeName) · ", attributes: caption))
    }
    var project = caption
    if let hex = entry.projectColor?.hexValue, let color = ProjectColor.nsColor(from: hex) {
      project[.foregroundColor] = color
    }
    text.append(NSAttributedString(string: entry.projectName, attributes: project))
    return text
  }

  static func image(for glyph: WorktreeHistoryEntry.Glyph) -> NSImage {
    let base: NSImage?
    let tint: NSColor
    switch glyph {
    case .branch:
      base = NSImage(named: "git-branch")
      tint = .secondaryLabelColor
    case .defaultBranch:
      base = NSImage(systemSymbolName: "star.fill", accessibilityDescription: "Default branch")
      tint = .secondaryLabelColor
    case .folder:
      base = NSImage(systemSymbolName: "folder", accessibilityDescription: "Project folder")
      tint = .secondaryLabelColor
    case .pullRequest(let state, let isDraft):
      base = NSImage(named: state.rowIconName(isDraft: isDraft))
      tint = NSColor(state.rowTint(isDraft: isDraft))
    }
    // Same 14pt slot the header gives `WorktreeRowIcon`. Drawn lazily so the
    // dynamic grey resolves against the menu's appearance.
    let side: CGFloat = 14
    let image = NSImage(size: NSSize(width: side, height: side), flipped: false) { bounds in
      guard let base, base.size.width > 0, base.size.height > 0 else { return false }
      let scale = min(bounds.width / base.size.width, bounds.height / base.size.height)
      let size = NSSize(width: base.size.width * scale, height: base.size.height * scale)
      let rect = NSRect(
        x: bounds.midX - size.width / 2, y: bounds.midY - size.height / 2,
        width: size.width, height: size.height
      )
      base.draw(in: rect)
      // `.sourceIn`, not `.sourceAtop`: the grey is translucent black, and
      // atop the glyph's opaque black it would stay black.
      tint.set()
      rect.fill(using: .sourceIn)
      return true
    }
    return image
  }
}

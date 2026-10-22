import ArgumentParser
import CodansCore
import CodansIPC
import CodansKit
import Foundation

/// `codans pane …` — the layout verbs. A Pane is a split-tree leaf that
/// holds a strip of Tabs; it never takes text or shows a screen. Every Pane
/// position accepts a Pane id or a Tab / Content id (resolved to its Pane),
/// a `p<n>` / `t<n>` handle, an `@label`, or `current` — except `close`,
/// which refuses a Tab so one session never takes its whole Pane down.
struct PaneCommand: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "pane",
    abstract: "Shape the layout: list, focus, split, close, resize, equalize, and zoom panes.",
    subcommands: [
      PaneList.self,
      PaneFocus.self,
      PaneSplit.self,
      PaneClose.self,
      PaneResize.self,
      PaneEqualize.self,
      PaneZoom.self,
      MovedPaneNew.self,
      MovedPaneShow.self,
      MovedPaneSend.self,
      MovedPaneSendKey.self,
      MovedPaneCapture.self,
      MovedPaneRead.self,
      MovedPaneInfo.self,
      MovedPaneLabel.self,
      MovedPaneReset.self,
    ]
  )
}

private let paneArgumentHelp = ArgumentHelp(
  "Pane: an id (pane, or tab / content → its pane), p<n>, t<n>, @label, or 'current'.")

enum SplitDirectionArgument: String, ExpressibleByArgument, CaseIterable {
  case right, left, up, down
}

struct PaneList: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "list",
    abstract: "List a worktree's panes in layout order."
  )

  @OptionGroup var globals: GlobalOptions
  @Option(name: .long, help: "Project id, name, or 'current'.")
  var project: String = "current"
  @Option(name: .long, help: "Worktree id, name, branch, or 'current'.")
  var worktree: String = "current"

  func run() async throws {
    await CommandRunner.run(self, globals: globals) {
      let client = CLISession.connect(globals: globals)
      defer { Task { await client.shutdown() } }
      let scope = try await ScopeResolver.layoutWorktree(project: project, worktree: worktree, client: client)
      struct Params: Codable {
        let worktreeID: WorktreeID
        let projectID: ProjectID
      }
      let result: PaneListPayload = try await client.call(
        .hierarchyListPanes,
        params: Params(worktreeID: scope.worktreeID, projectID: scope.projectID)
      )
      try Renderer.emit(PaneListRenderable(panes: result.panes), mode: globals.renderMode)
    }
  }
}

struct PaneFocus: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "focus",
    abstract: "Give a pane the keyboard, by id or by direction.",
    discussion: """
      With a pane, focus it. With --direction, move focus from the pane
      (default: the focused pane of the current worktree) to its neighbour
      that way, as the keyboard does; at an edge nothing moves.
      """
  )

  enum Direction: String, ExpressibleByArgument, CaseIterable {
    case left, right, up, down, previous, next
  }

  @OptionGroup var globals: GlobalOptions
  @Argument(help: paneArgumentHelp)
  var pane: String?
  @Option(name: .long, help: "Move focus: left, right, up, down, previous, or next.")
  var direction: Direction?
  @Option(name: .long, help: "Project id, name, or 'current' (with --direction and no pane).")
  var project: String = "current"
  @Option(name: .long, help: "Worktree id, name, branch, or 'current' (with --direction and no pane).")
  var worktree: String = "current"

  func run() async throws {
    await CommandRunner.run(self, globals: globals) {
      guard pane != nil || direction != nil else {
        throw CLIError(code: .userError, message: "pass a pane, --direction, or both")
      }
      let client = CLISession.connect(globals: globals)
      defer { Task { await client.shutdown() } }
      struct Params: Codable {
        let id: PaneID?
        let projectID: ProjectID?
        let worktreeID: WorktreeID?
        let direction: String?
      }
      let params: Params
      if let pane {
        let paneID = PaneID(raw: try await AliasResolver.resolve(pane, kind: .pane, client: client))
        params = Params(id: paneID, projectID: nil, worktreeID: nil, direction: direction?.rawValue)
      } else {
        let scope = try await ScopeResolver.layoutWorktree(project: project, worktree: worktree, client: client)
        params = Params(
          id: nil, projectID: scope.projectID, worktreeID: scope.worktreeID, direction: direction?.rawValue)
      }
      struct Result: Codable {
        let paneID: PaneID
        let moved: Bool
      }
      let result: Result = try await client.call(.hierarchyFocusPane, params: params)
      try Renderer.emitObject(
        ["paneID": result.paneID.description, "moved": result.moved], mode: globals.renderMode
      ) { _ in
        result.moved ? "focused pane \(result.paneID)" : "no pane \(direction?.rawValue ?? "") of \(result.paneID)"
      }
    }
  }
}

struct PaneSplit: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "split",
    abstract: "Split a pane: a new pane beside it, with a new tab running a shell (or a command).",
    discussion: """
      The new pane appears beside the anchor pane in the given direction,
      like the keyboard split. Its working directory defaults to the anchor
      pane's selected tab's live directory, not $PWD; pass --cwd to choose
      another. The one positional is the anchor; a command goes in --command
      so the two never compete for the same slot. Prints the new tab's id so
      the next command can drive it; the JSON result also carries the new
      pane and content ids.
      """
  )

  @OptionGroup var globals: GlobalOptions
  @Argument(help: paneArgumentHelp)
  var pane: String = "current"
  @Option(name: .long, help: "Initial command for the new tab. Omit for the default shell.")
  var command: String?
  @Option(name: .long, help: "Side of the anchor the new pane takes: right (default), left, up, down.")
  var direction: SplitDirectionArgument = .right
  @Option(name: .long, help: "Working directory. Defaults to the anchor pane's directory.")
  var cwd: String?
  @Option(name: .long, parsing: .upToNextOption, help: "Initial labels.")
  var label: [String] = []

  func run() async throws {
    await CommandRunner.run(self, globals: globals) {
      let client = CLISession.connect(globals: globals)
      defer { Task { await client.shutdown() } }
      let anchor = PaneID(raw: try await AliasResolver.resolve(pane, kind: .pane, client: client))
      struct Params: Codable {
        let paneID: UUID
        let direction: String
        let workingDirectory: String?
        let initialCommand: String?
        let labels: [String]
      }
      struct Result: Codable {
        let paneID: PaneID
        let tabID: TabID
        let contentID: ContentID
      }
      let result: Result = try await client.call(
        .hierarchySplitPane,
        params: Params(
          paneID: anchor.raw,
          direction: direction.rawValue,
          workingDirectory: cwd.map { PathResolver.absolute($0) },
          initialCommand: command.flatMap { $0.trimmingCharacters(in: .whitespaces).isEmpty ? nil : $0 },
          labels: label
        )
      )
      try Renderer.emitObject(
        [
          "paneID": result.paneID.description,
          "tabID": result.tabID.description,
          "contentID": result.contentID.description,
          "anchor": anchor.description,
          "direction": direction.rawValue,
        ],
        mode: globals.renderMode
      ) { _ in
        result.tabID.description
      }
    }
  }
}

struct PaneClose: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "close",
    abstract: "Close a pane and every tab on its strip.",
    discussion: """
      Each tab's session ends as with `tab close` (its terminal daemon is
      killed). Only a pane id, p<n>, or 'current' is accepted: a tab or
      content id is refused, so a script that meant one session never
      closes a whole pane — use `tab close` for that.
      """
  )

  @OptionGroup var globals: GlobalOptions
  @Argument(help: "Pane: a pane id, p<n>, or 'current'.")
  var pane: String

  func run() async throws {
    await CommandRunner.run(self, globals: globals) {
      let client = CLISession.connect(globals: globals)
      defer { Task { await client.shutdown() } }
      let match = try await AliasResolver.resolveMatch(pane, kind: .pane, client: client)
      if let matched = match.matched, matched != .pane {
        throw CLIError(
          code: .userError,
          message: "\(pane) names a \(matched == .content ? "content (session)" : "tab"), not a pane;"
            + " `pane close` closes a whole pane with all its tabs",
          hint: "use `\(CodansCLI.commandName) tab close \(pane)` to close one tab",
          errorCode: .invalidArgument,
          details: ["kind": matched.rawValue, "value": pane])
      }
      struct Params: Codable { let id: UUID }
      struct Result: Codable {
        let id: PaneID
        let tabIDs: [TabID]
      }
      let result: Result = try await client.call(.hierarchyClosePane, params: Params(id: match.id))
      try Renderer.emitObject(
        ["id": result.id.description, "tabIDs": result.tabIDs.map(\.description)],
        mode: globals.renderMode
      ) { _ in
        "closed pane \(result.id) (\(result.tabIDs.count) tab\(result.tabIDs.count == 1 ? "" : "s"))"
      }
    }
  }
}

struct PaneResize: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "resize",
    abstract: "Move the divider next to a pane.",
    discussion: """
      `left` / `right` move the nearest vertical divider, `up` / `down` the
      nearest horizontal one, growing the pane toward that side. A pane with
      no divider in that orientation is left alone. --amount is in pixels,
      as the keyboard resize sends them (default 40).
      """
  )

  @OptionGroup var globals: GlobalOptions
  @Argument(help: paneArgumentHelp)
  var pane: String
  @Argument(help: "Direction to grow: left, right, up, or down.")
  var direction: SplitDirectionArgument
  @Option(name: .long, help: "Pixels to move the divider (default 40).")
  var amount: Double = 40

  func run() async throws {
    await CommandRunner.run(self, globals: globals) {
      guard amount > 0 else {
        throw CLIError(code: .userError, message: "--amount must be positive")
      }
      let client = CLISession.connect(globals: globals)
      defer { Task { await client.shutdown() } }
      let paneID = PaneID(raw: try await AliasResolver.resolve(pane, kind: .pane, client: client))
      struct Params: Codable {
        let paneID: UUID
        let direction: String
        let amount: Double
      }
      _ = try await client.callRaw(
        .hierarchyResizePane,
        params: Params(paneID: paneID.raw, direction: direction.rawValue, amount: amount)
      )
      try Renderer.emit(
        IDMessage(id: paneID.description, message: "resized pane \(paneID) \(direction.rawValue)"),
        mode: globals.renderMode
      )
    }
  }
}

struct PaneEqualize: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "equalize",
    abstract: "Give every pane of a worktree an even share of the layout."
  )

  @OptionGroup var globals: GlobalOptions
  @Option(name: .long, help: "Project id, name, or 'current'.")
  var project: String = "current"
  @Option(name: .long, help: "Worktree id, name, branch, or 'current'.")
  var worktree: String = "current"

  func run() async throws {
    await CommandRunner.run(self, globals: globals) {
      let client = CLISession.connect(globals: globals)
      defer { Task { await client.shutdown() } }
      let scope = try await ScopeResolver.layoutWorktree(project: project, worktree: worktree, client: client)
      struct Params: Codable {
        let projectID: ProjectID
        let worktreeID: WorktreeID
      }
      _ = try await client.callRaw(
        .hierarchyEqualizePanes, params: Params(projectID: scope.projectID, worktreeID: scope.worktreeID))
      try Renderer.emit(
        IDMessage(id: scope.worktreeID.description, message: "equalized panes of worktree \(scope.worktreeID)"),
        mode: globals.renderMode
      )
    }
  }
}

struct PaneZoom: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "zoom",
    abstract: "Toggle zoom: the pane fills the layout area; again to return.",
    discussion: """
      A zoomed pane fills the layout area and keeps its tab strip; the
      other panes are hidden, not closed. Running it on the zoomed pane
      (or --off) returns to the layout.
      """
  )

  @OptionGroup var globals: GlobalOptions
  @Argument(help: paneArgumentHelp)
  var pane: String = "current"
  @Flag(name: .long, help: "Only leave the zoom; never zoom in.")
  var off: Bool = false

  func run() async throws {
    await CommandRunner.run(self, globals: globals) {
      let client = CLISession.connect(globals: globals)
      defer { Task { await client.shutdown() } }
      let paneID = PaneID(raw: try await AliasResolver.resolve(pane, kind: .pane, client: client))
      struct Params: Codable { let id: UUID }
      struct Result: Codable {
        let paneID: PaneID
        let zoomed: Bool
      }
      let result: Result = try await client.call(
        off ? .hierarchyUnzoomPane : .hierarchyZoomPane, params: Params(id: paneID.raw))
      try Renderer.emitObject(
        ["paneID": result.paneID.description, "zoomed": result.zoomed], mode: globals.renderMode
      ) { _ in
        result.zoomed ? "zoomed pane \(result.paneID)" : "pane \(result.paneID) not zoomed"
      }
    }
  }
}

struct PaneListPayload: Codable { let panes: [IPC.PaneDescription] }

struct PaneListRenderable: Encodable, CustomStringConvertible {
  let panes: [IPC.PaneDescription]
  private enum Key: String, CodingKey { case panes }

  func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: Key.self)
    try container.encode(panes, forKey: .panes)
  }

  var description: String {
    panes.isEmpty
      ? "(no panes)"
      : panes.map { pane in
        let focused = pane.isFocused ? "*" : " "
        let handle = pane.handle.map { "\($0)  " } ?? ""
        let selected = pane.selectedTabID.map { "  selected \($0)" } ?? ""
        return "[\(focused)] \(handle)\(pane.id)  (\(pane.tabIDs.count) tabs)\(selected)"
      }.joined(separator: "\n")
  }
}

// MARK: - Verbs that moved to `tab`

/// A verb at its former location: parses anything and fails with the new
/// location, in text or JSON as the caller asked. Hidden from help.
protocol MovedVerbCommand: AsyncParsableCommand {
  static var formerPath: String { get }
  var passthrough: [String] { get }
}

extension MovedVerbCommand {
  static func movedConfiguration(_ name: String) -> CommandConfiguration {
    CommandConfiguration(commandName: name, shouldDisplay: false)
  }

  func run() async throws {
    let text = CLIMovedVerb.message(executable: CodansCLI.commandName, from: Self.formerPath)
    let mode: RenderMode = passthrough.contains("--json") ? .json : .text(useColor: true)
    let context = RenderContext(command: CommandPaths.path(for: Self.self))
    await Renderer.$context.withValue(context) {
      CLIError(
        code: .userError, message: text.message, hint: text.hint, errorCode: .movedVerb,
        details: ["moved": Self.formerPath, "to": CLIMovedVerb.table[Self.formerPath] ?? ""]
      ).exitProcess(mode: mode)
    }
  }
}

struct MovedPaneNew: MovedVerbCommand {
  static let configuration = movedConfiguration("new")
  static let formerPath = "pane new"
  @Argument(parsing: .captureForPassthrough) var passthrough: [String] = []
}

struct MovedPaneShow: MovedVerbCommand {
  static let configuration = movedConfiguration("show")
  static let formerPath = "pane show"
  @Argument(parsing: .captureForPassthrough) var passthrough: [String] = []
}

struct MovedPaneSend: MovedVerbCommand {
  static let configuration = movedConfiguration("send")
  static let formerPath = "pane send"
  @Argument(parsing: .captureForPassthrough) var passthrough: [String] = []
}

struct MovedPaneSendKey: MovedVerbCommand {
  static let configuration = movedConfiguration("send-key")
  static let formerPath = "pane send-key"
  @Argument(parsing: .captureForPassthrough) var passthrough: [String] = []
}

struct MovedPaneCapture: MovedVerbCommand {
  static let configuration = movedConfiguration("capture")
  static let formerPath = "pane capture"
  @Argument(parsing: .captureForPassthrough) var passthrough: [String] = []
}

struct MovedPaneRead: MovedVerbCommand {
  static let configuration = movedConfiguration("read")
  static let formerPath = "pane read"
  @Argument(parsing: .captureForPassthrough) var passthrough: [String] = []
}

struct MovedPaneInfo: MovedVerbCommand {
  static let configuration = movedConfiguration("info")
  static let formerPath = "pane info"
  @Argument(parsing: .captureForPassthrough) var passthrough: [String] = []
}

struct MovedPaneLabel: MovedVerbCommand {
  static let configuration = movedConfiguration("label")
  static let formerPath = "pane label"
  @Argument(parsing: .captureForPassthrough) var passthrough: [String] = []
}

struct MovedPaneReset: MovedVerbCommand {
  static let configuration = movedConfiguration("reset")
  static let formerPath = "pane reset"
  @Argument(parsing: .captureForPassthrough) var passthrough: [String] = []
}

struct MovedTabSwitch: MovedVerbCommand {
  static let configuration = movedConfiguration("switch")
  static let formerPath = "tab switch"
  @Argument(parsing: .captureForPassthrough) var passthrough: [String] = []
}

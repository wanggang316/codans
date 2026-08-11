import ArgumentParser
import Foundation
import CodansCore
import CodansIPC
import CodansKit

struct SendCommand: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "send",
    abstract: "Send text to a pane.",
    discussion: """
      With one positional argument, send it to the current pane.
      With two positional arguments, the first is the target pane and the second is text.
      Text is submitted with Enter by default; pass --no-enter to only type it.

      Use --raw <hex> to ship raw bytes (e.g. CSI sequences) that the text
      path drops. Hex may include "0x" and whitespace. Control bytes (ESC,
      Tab, BS, CR/LF, Ctrl-A..Z) are dispatched as key events so the PTY
      actually receives them; printable bytes ride the text channel.
      Cannot combine with positional text, --stdin, or --no-enter.
      """
  )

  @OptionGroup var globals: GlobalOptions
  @Option(name: [.customShort("p"), .long], help: "Target pane id, p<n> handle, @label, or 'current'.")
  var pane: String?
  @Argument(parsing: .remaining, help: "Text, or target followed by text.")
  var arguments: [String] = []
  @Flag(name: .long, help: "Read text from stdin.")
  var stdin: Bool = false
  @Flag(name: .long, help: "Do not send trailing Enter after text.")
  var noEnter: Bool = false
  @Option(name: .long, help: "Send raw bytes as a hex string (e.g. 1b5b41 for ESC [ A).")
  var raw: String?
  @Flag(name: .long, help: "Focus the target pane after sending.")
  var focus: Bool = false

  func run() async throws {
    await CommandRunner.run {
      if let raw {
        try await runRaw(hex: raw)
        return
      }
      let input = try CLISendInput.resolve(
        arguments: arguments,
        explicitPane: pane,
        stdin: stdin ? try StandardInput.readString() : nil,
        readsStdin: stdin,
        noEnter: noEnter
      )
      let client = CLISession.connect(globals: globals)
      defer { Task { await client.shutdown() } }
      let uuid = try await AliasResolver.resolve(input.target, kind: .pane, client: client)
      if focus {
        try await activatePane(uuid, client: client)
      }
      struct Params: Codable {
        let paneID: PaneID
        let text: String
      }
      _ = try await client.callRaw(
        .terminalSendInput,
        params: Params(paneID: PaneID(raw: uuid), text: input.text)
      )
      try Renderer.emitObject(
        ["paneID": uuid.uuidString, "bytes": input.text.utf8.count],
        mode: globals.renderMode
      ) { obj in
        "sent \(obj["bytes"] ?? 0) bytes to \(obj["paneID"] ?? "?")"
      }
    }
  }

  private func runRaw(hex: String) async throws {
    if stdin || noEnter {
      throw CLIError(
        code: .userError,
        message: "--raw is exclusive of --stdin and --no-enter"
      )
    }
    let target: String
    switch (pane, arguments.count) {
    case (let explicit?, 0): target = explicit
    case (nil, 0): target = "current"
    case (nil, 1): target = arguments[0]
    case (_?, _):
      throw CLIError(
        code: .userError,
        message: "--raw with --pane takes no positional arguments"
      )
    default:
      throw CLIError(
        code: .userError,
        message: "--raw expects at most one positional pane id, got \(arguments.count)"
      )
    }
    let client = CLISession.connect(globals: globals)
    defer { Task { await client.shutdown() } }
    let uuid = try await AliasResolver.resolve(target, kind: .pane, client: client)
    if focus {
      try await activatePane(uuid, client: client)
    }
    struct Params: Codable {
      let paneID: PaneID
      let hex: String
    }
    struct Result: Codable {
      let bytes: Int
    }
    let result: Result = try await client.call(
      .terminalSendRawBytes,
      params: Params(paneID: PaneID(raw: uuid), hex: hex)
    )
    try Renderer.emitObject(
      ["paneID": uuid.uuidString, "bytes": result.bytes],
      mode: globals.renderMode
    ) { obj in
      "sent \(obj["bytes"] ?? 0) raw bytes to \(obj["paneID"] ?? "?")"
    }
  }
}

struct SendKeyCommand: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "send-key",
    abstract: "Send a named special key to a pane.",
    discussion: """
      With one positional argument, send the key to the current pane.
      With two positional arguments, the first is the target pane and the
      second is the key name. The --pane / -p option is an alternative way
      to pin a target.

      Named keys are dispatched as ghostty key events so the terminal sees
      the same byte sequences a physical keypress would emit (CSI for
      arrows, 0x1B for escape, 0x09 for tab, and so on).

      Supported keys: escape, up, down, left, right, tab, enter, backspace,
      delete, home, end, pgup, pgdn, f1..f12, ctrl_c, ctrl_d, ctrl_l, ctrl_z.
      """
  )

  @OptionGroup var globals: GlobalOptions
  @Option(name: [.customShort("p"), .long], help: "Target pane id, p<n> handle, @label, or 'current'.")
  var pane: String?
  @Argument(parsing: .remaining, help: "Key, or target followed by key.")
  var arguments: [String] = []
  @Flag(name: .long, help: "Focus the target pane after sending.")
  var focus: Bool = false

  func run() async throws {
    await CommandRunner.run {
      let (target, keyName) = try Self.resolveTargetAndKey(arguments: arguments, explicitPane: pane)
      let normalised = keyName.lowercased().replacingOccurrences(of: "-", with: "_")
      guard let named = IPC.TerminalNamedKey(rawValue: normalised) else {
        let names = IPC.TerminalNamedKey.allCases.map(\.rawValue).joined(separator: ", ")
        throw CLIError(
          code: .userError,
          message: "unknown key \"\(keyName)\". Supported: \(names)"
        )
      }
      let client = CLISession.connect(globals: globals)
      defer { Task { await client.shutdown() } }
      let uuid = try await AliasResolver.resolve(target, kind: .pane, client: client)
      if focus {
        try await activatePane(uuid, client: client)
      }
      struct Params: Codable {
        let paneID: PaneID
        let key: IPC.TerminalNamedKey
      }
      _ = try await client.callRaw(
        .terminalSendKey,
        params: Params(paneID: PaneID(raw: uuid), key: named)
      )
      try Renderer.emitObject(
        ["paneID": uuid.uuidString, "key": named.rawValue],
        mode: globals.renderMode
      ) { obj in
        "sent \(obj["key"] ?? "?") to \(obj["paneID"] ?? "?")"
      }
    }
  }

  /// Mirrors `codans pane send`'s positional handling: one arg = key (target
  /// is current pane), two args = `<pane> <key>`. The `-p/--pane` flag is
  /// honoured when present and is mutually exclusive with a positional
  /// pane.
  static func resolveTargetAndKey(arguments: [String], explicitPane: String?) throws -> (String, String) {
    if let explicitPane {
      switch arguments.count {
      case 1: return (explicitPane, arguments[0])
      case 0: throw CLIError(code: .userError, message: "missing key name")
      default:
        throw CLIError(
          code: .userError,
          message: "expected one positional key when --pane is set, got \(arguments.count)"
        )
      }
    }
    switch arguments.count {
    case 1: return ("current", arguments[0])
    case 2: return (arguments[0], arguments[1])
    case 0: throw CLIError(code: .userError, message: "missing key name")
    default:
      throw CLIError(
        code: .userError,
        message: "expected <key> or <pane> <key>, got \(arguments.count) positional arguments"
      )
    }
  }
}

struct ReadCommand: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "read",
    abstract: "Read text from a pane.",
    discussion: """
      Reads the visible viewport by default. Use --screen for the active screen
      buffer, or --selection for the current selection.
      """
  )

  enum Extent: String, ExpressibleByArgument {
    case viewport
    case screen
    case selection
  }

  @OptionGroup var globals: GlobalOptions
  @Argument(help: "Pane id, p<n> handle, @label, or 'current'.")
  var pane: String = "current"
  @Option(name: .long, help: "Text extent to read: viewport, screen, or selection.")
  var extent: Extent = .viewport
  @Flag(name: .long, help: "Shortcut for --extent screen.")
  var screen: Bool = false
  @Flag(name: .long, help: "Shortcut for --extent selection.")
  var selection: Bool = false

  func run() async throws {
    await CommandRunner.run {
      if screen && selection {
        throw CLIError(code: .userError, message: "pass at most one of --screen or --selection")
      }
      let resolvedExtent: Extent = selection ? .selection : (screen ? .screen : extent)
      let client = CLISession.connect(globals: globals)
      defer { Task { await client.shutdown() } }
      let uuid = try await AliasResolver.resolve(pane, kind: .pane, client: client)
      struct Params: Codable {
        let paneID: PaneID
        let extent: String
      }
      struct Result: Codable {
        let text: String
      }
      let result: Result = try await client.call(
        .terminalReadText,
        params: Params(paneID: PaneID(raw: uuid), extent: resolvedExtent.rawValue)
      )
      try Renderer.emitObject(
        ["paneID": uuid.uuidString, "extent": resolvedExtent.rawValue, "text": result.text],
        mode: globals.renderMode
      ) { obj in
        obj["text"] as? String ?? ""
      }
    }
  }
}

struct CaptureCommand: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "capture",
    abstract: "Capture a pane's rendered text.",
    discussion: """
      Plain-text snapshot of what's currently rendered in the pane. Reads
      the visible viewport by default; pass --scope screen for the whole
      active screen buffer (scrolled-off rows included).

      Use --lines=N to keep only the last N non-empty trailing lines.

      Pass --wait-stable to poll the pane until its rendered text stops
      changing before capturing — useful after firing a command or agent
      to wait for it to actually settle instead of a fixed sleep. Tune with
      --stable-ms (quiet window, default 500), --interval-ms (poll cadence,
      default 100), and --timeout-ms (overall cap, default 5000). In --json
      mode the result carries stabilized / waitedMs / samples; keep
      --timeout-ms below the client --timeout (default 10s).

      Raw ANSI byte stream capture (OSC/CSI/APC) is not currently
      supported — libghostty exposes parsed text only, not the original
      PTY byte stream. Tracked as a follow-up.
      """
  )

  enum Scope: String, ExpressibleByArgument {
    case viewport
    case screen
  }

  @OptionGroup var globals: GlobalOptions
  @Argument(help: "Pane id, p<n> handle, @label, or 'current'.")
  var pane: String = "current"
  @Option(name: .long, help: "Capture scope: viewport (default) or screen.")
  var scope: Scope = .viewport
  @Option(name: .long, help: "Trim output to the last N non-empty lines.")
  var lines: Int?
  @Flag(name: .long, help: "Poll until the rendered text stops changing before capturing.")
  var waitStable: Bool = false
  @Option(name: .long, help: "Wait-stable: quiet window in ms the output must hold unchanged (default 500).")
  var stableMs: Int = 500
  @Option(name: .long, help: "Wait-stable: poll interval in ms (default 100).")
  var intervalMs: Int = 100
  @Option(name: .long, help: "Wait-stable: overall cap in ms before giving up (default 5000).")
  var timeoutMs: Int = 5000

  func run() async throws {
    await CommandRunner.run {
      struct WaitStablePayload: Codable {
        let stableMillis: Int
        let intervalMillis: Int
        let timeoutMillis: Int
      }
      struct Params: Codable {
        let paneID: PaneID
        let extent: String
        let waitStable: WaitStablePayload?
      }
      struct Result: Codable {
        let text: String
        let stabilized: Bool?
        let waitedMillis: Int?
        let samples: Int?
      }
      if let lines, lines <= 0 {
        throw CLIError(code: .userError, message: "--lines must be a positive integer")
      }
      var wait: WaitStablePayload?
      if waitStable {
        guard stableMs > 0, intervalMs > 0, timeoutMs > 0 else {
          throw CLIError(
            code: .userError,
            message: "--stable-ms, --interval-ms, and --timeout-ms must be positive")
        }
        guard Double(timeoutMs) / 1000.0 < globals.timeout else {
          throw CLIError(
            code: .userError,
            message:
              "--timeout-ms (\(timeoutMs)ms) must be below the client --timeout (\(globals.timeout)s); raise --timeout")
        }
        wait = WaitStablePayload(
          stableMillis: stableMs, intervalMillis: intervalMs, timeoutMillis: timeoutMs)
      }
      let client = CLISession.connect(globals: globals)
      defer { Task { await client.shutdown() } }
      let uuid = try await AliasResolver.resolve(pane, kind: .pane, client: client)
      let result: Result = try await client.call(
        .terminalReadText,
        params: Params(paneID: PaneID(raw: uuid), extent: scope.rawValue, waitStable: wait)
      )
      let trimmed = Self.trim(result.text, lastLines: lines)
      var object: [String: Any] = [
        "paneID": uuid.uuidString,
        "scope": scope.rawValue,
        "lines": trimmed.lineCount,
        "text": trimmed.text,
      ]
      if waitStable {
        object["stabilized"] = result.stabilized ?? false
        object["waitedMs"] = result.waitedMillis ?? 0
        object["samples"] = result.samples ?? 0
      }
      try Renderer.emitObject(object, mode: globals.renderMode) { obj in
        obj["text"] as? String ?? ""
      }
    }
  }

  struct Trimmed {
    let text: String
    let lineCount: Int
  }

  static func trim(_ text: String, lastLines: Int?) -> Trimmed {
    // Split on newlines, drop empty trailing rows (typical when reading a
    // viewport with blank rows at the bottom), then take the last N.
    var rows = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
    while let last = rows.last, last.trimmingCharacters(in: .whitespaces).isEmpty {
      rows.removeLast()
    }
    if let lastLines, rows.count > lastLines {
      rows = Array(rows.suffix(lastLines))
    }
    return Trimmed(text: rows.joined(separator: "\n"), lineCount: rows.count)
  }
}

private func activatePane(_ uuid: UUID, client: RPCClient) async throws {
  let path = try await PaneLocatorFlow.resolvePanePath(
    paneUUID: uuid,
    project: "current",
    worktree: "current",
    tab: "current",
    client: client
  )
  _ = try await client.callRaw(
    .hierarchyFocusPane,
    params: PaneLocatorBody(
      id: path.paneID,
      tabID: path.tabID,
      worktreeID: path.worktreeID,
      projectID: path.projectID
    )
  )
}

struct BroadcastCommand: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "broadcast",
    abstract: "Send text to a tab, worktree, or label scope."
  )

  @OptionGroup var globals: GlobalOptions
  @Option(name: .long, help: "Tab id, t<n> handle, or 'current'.")
  var tab: String?
  @Option(name: .long, help: "Worktree id or 'current'.")
  var worktree: String?
  @Option(name: .long, help: "Pane label.")
  var label: String?
  @Argument(parsing: .remaining, help: "Text to send.")
  var text: [String] = []
  @Flag(name: .long, help: "Read text from stdin.")
  var stdin: Bool = false
  @Flag(name: .long, help: "Do not send trailing Enter after text.")
  var noEnter: Bool = false

  func run() async throws {
    await CommandRunner.run {
      if stdin && !text.isEmpty {
        throw CLIArgumentError.conflictingTextSources
      }
      let payload = try CLICommandText.resolve(
        pieces: text,
        stdin: stdin ? try StandardInput.readString() : nil,
        readsStdin: stdin
      )
      let submitted = CLICommandText.appendEnterIfNeeded(payload, noEnter: noEnter)
      let selected = try CLIBroadcastScopeSelection.resolve(
        tab: tab,
        worktree: worktree,
        label: label
      )
      let client = CLISession.connect(globals: globals)
      defer { Task { await client.shutdown() } }
      let scope = try await resolveScope(selected, client: client)
      struct Params: Codable {
        let scope: IPC.BroadcastScope
        let text: String
      }
      struct Result: Codable { let delivered: Int }
      let result: Result = try await client.call(
        .terminalBroadcastInput,
        params: Params(scope: scope, text: submitted)
      )
      try Renderer.emitObject(
        ["delivered": result.delivered, "bytes": submitted.utf8.count],
        mode: globals.renderMode
      ) { obj in
        "broadcast \(obj["bytes"] ?? 0) bytes to \(obj["delivered"] ?? 0) pane(s)"
      }
    }
  }

  private func resolveScope(
    _ selection: CLIBroadcastScopeSelection,
    client: RPCClient
  ) async throws -> IPC.BroadcastScope {
    switch selection {
    case .tab(let value):
      let uuid = try await AliasResolver.resolve(value, kind: .tab, client: client)
      return .tab(TabID(raw: uuid))
    case .worktree(let value):
      let uuid = try await AliasResolver.resolve(value, kind: .worktree, client: client)
      return .worktree(WorktreeID(raw: uuid))
    case .label(let value):
      return .label(value)
    }
  }
}

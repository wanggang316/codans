import ArgumentParser
import CodansCore
import CodansIPC
import CodansKit
import Foundation

/// `send`, `send-key`, and `capture` exist twice: under `tab` (the session
/// verbs) and at the top level. Both spellings share one option set and
/// one body; only the command path (and so the JSON `schemaVersion`)
/// differs.

struct SendOptions: ParsableArguments {
  @Option(
    name: [.customShort("t"), .long], help: "Target tab: an id (pane, tab, or content), t<n>, @label, or 'current'.")
  var tab: String?
  @Option(name: [.customShort("p"), .long], help: "Target pane (its selected tab): an id, p<n>, or 'current'.")
  var pane: String?
  @Argument(parsing: .remaining, help: "Text, or target tab followed by text.")
  var arguments: [String] = []
  @Flag(name: .long, help: "Read text from stdin.")
  var stdin: Bool = false
  @Flag(name: .long, help: "Do not send trailing Enter after text.")
  var noEnter: Bool = false
  @Option(name: .long, help: "Send raw bytes as a hex string (e.g. 1b5b41 for ESC [ A).")
  var raw: String?
  @Flag(name: .long, help: "Select the target tab and focus its pane after sending.")
  var focus: Bool = false
  @Flag(name: .long, help: "Wait until the command the text started has finished.")
  var wait: Bool = false
  @Flag(name: .long, help: "Wait, and return the output the command produced (implies --wait).")
  var capture: Bool = false
  @Option(name: .long, help: "Seconds to wait for completion with --wait / --capture (1 through 600, default 30).")
  var waitTimeout: Double = 30
  @Option(name: .long, help: "With --wait: the screen must hold still this long, in ms (default 500).")
  var stableMs: Int = 500

  static let discussion = """
    With one positional argument, send it to the current tab.
    With two positional arguments, the first is the target tab and the second is text.
    --tab / --pane name the target instead; --pane means that pane's selected tab.
    Text is submitted with Enter by default; pass --no-enter to only type it.

    Use --raw <hex> to ship raw bytes (e.g. CSI sequences) that the text
    path drops. Hex may include "0x" and whitespace. Control bytes (ESC,
    Tab, BS, CR/LF, Ctrl-A..Z) are dispatched as key events so the PTY
    actually receives them; printable bytes ride the text channel.
    Cannot combine with positional text, --stdin, or --no-enter.

    --wait returns once the command the text started has finished: the
    tab's shell is no longer running a foreground job and the screen
    has held still for --stable-ms. --capture (implies --wait) also
    returns the lines the command printed. A command that is still
    running at --wait-timeout fails with WAIT_TIMEOUT (exit 11).
    """

  func run(globals: GlobalOptions) async throws {
    let explicit = try CLITargetSelection.explicit(tab: tab, pane: pane)
    if let raw {
      if wait || capture {
        throw CLIError(code: .userError, message: "--raw cannot be combined with --wait / --capture")
      }
      try await runRaw(hex: raw, explicit: explicit, globals: globals)
      return
    }
    let waiting = wait || capture
    if waiting {
      guard waitTimeout >= 1, waitTimeout <= 600 else {
        throw CLIError(code: .userError, message: "--wait-timeout must be between 1 and 600 seconds")
      }
      guard stableMs > 0 else {
        throw CLIError(code: .userError, message: "--stable-ms must be positive")
      }
    }
    // A `--tab` / `--pane` target leaves every positional to the text.
    let input = try CLISendInput.resolve(
      arguments: arguments,
      explicitTarget: explicit == nil ? nil : "explicit",
      stdin: stdin ? try StandardInput.readString() : nil,
      readsStdin: stdin,
      noEnter: noEnter
    )
    let selection = explicit ?? .tab(input.target)
    let client = CLISession.connect(globals: globals)
    defer { Task { await client.shutdown() } }
    let target = try await TabTarget.resolve(selection, client: client)
    if focus {
      try await TabTarget.activate(target, client: client)
    }
    struct WaitParams: Codable {
      let timeoutMillis: Int
      let stableMillis: Int
    }
    struct Params: Codable {
      let contentID: ContentID
      let text: String
      let wait: WaitParams?
      let capture: Bool
    }
    struct Result: Codable {
      let delivered: Bool
      let completed: Bool?
      let waitedMillis: Int?
      let busyObserved: Bool?
      let output: String?
    }
    let result: Result = try await client.call(
      .terminalSendInput,
      params: Params(
        contentID: target.contentID,
        text: input.text,
        wait: waiting ? WaitParams(timeoutMillis: Int(waitTimeout * 1000), stableMillis: stableMs) : nil,
        capture: capture
      ),
      timeout: waiting ? .seconds(waitTimeout + 5) : nil
    )
    if waiting, result.completed != true {
      throw CLIError(
        code: .requestTimeout,
        message: "command in tab \(target.tabID) still running after \(Int(waitTimeout))s",
        hint: "raise --wait-timeout, or read the tab with `tab capture` later",
        errorCode: .waitTimeout,
        details: [
          "tabID": target.tabID.description, "contentID": target.contentID.description,
          "waitedMs": String(result.waitedMillis ?? 0),
        ])
    }
    var object = target.jsonFields
    object["bytes"] = input.text.utf8.count
    if waiting {
      object["completed"] = result.completed ?? false
      object["waitedMs"] = result.waitedMillis ?? 0
      object["busyObserved"] = result.busyObserved ?? false
    }
    if capture {
      object["output"] = result.output ?? ""
    }
    try Renderer.emitObject(object, mode: globals.renderMode) { obj in
      if capture { return obj["output"] as? String ?? "" }
      if waiting {
        return "sent \(obj["bytes"] ?? 0) bytes to tab \(target.tabID); completed after \(obj["waitedMs"] ?? 0)ms"
      }
      return "sent \(obj["bytes"] ?? 0) bytes to tab \(target.tabID)"
    }
  }

  private func runRaw(hex: String, explicit: CLITargetSelection?, globals: GlobalOptions) async throws {
    if stdin || noEnter {
      throw CLIError(code: .userError, message: "--raw is exclusive of --stdin and --no-enter")
    }
    let selection: CLITargetSelection
    switch (explicit, arguments.count) {
    case (let explicit?, 0): selection = explicit
    case (nil, 0): selection = .tab("current")
    case (nil, 1): selection = .tab(arguments[0])
    case (_?, _):
      throw CLIError(code: .userError, message: "--raw with --tab / --pane takes no positional arguments")
    default:
      throw CLIError(
        code: .userError, message: "--raw expects at most one positional tab, got \(arguments.count)")
    }
    let client = CLISession.connect(globals: globals)
    defer { Task { await client.shutdown() } }
    let target = try await TabTarget.resolve(selection, client: client)
    if focus {
      try await TabTarget.activate(target, client: client)
    }
    struct Params: Codable {
      let contentID: ContentID
      let hex: String
    }
    struct Result: Codable { let bytes: Int }
    let result: Result = try await client.call(
      .terminalSendRawBytes,
      params: Params(contentID: target.contentID, hex: hex)
    )
    var object = target.jsonFields
    object["bytes"] = result.bytes
    try Renderer.emitObject(object, mode: globals.renderMode) { obj in
      "sent \(obj["bytes"] ?? 0) raw bytes to tab \(target.tabID)"
    }
  }
}

struct TabSend: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "send", abstract: "Send text to a tab.", discussion: SendOptions.discussion)

  @OptionGroup var globals: GlobalOptions
  @OptionGroup var options: SendOptions

  func run() async throws {
    await CommandRunner.run(self, globals: globals) { try await options.run(globals: globals) }
  }
}

struct SendCommand: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "send", abstract: "Send text to a tab (same as `tab send`).", discussion: SendOptions.discussion)

  @OptionGroup var globals: GlobalOptions
  @OptionGroup var options: SendOptions

  func run() async throws {
    await CommandRunner.run(self, globals: globals) { try await options.run(globals: globals) }
  }
}

struct SendKeyOptions: ParsableArguments {
  @Option(
    name: [.customShort("t"), .long], help: "Target tab: an id (pane, tab, or content), t<n>, @label, or 'current'.")
  var tab: String?
  @Option(name: [.customShort("p"), .long], help: "Target pane (its selected tab): an id, p<n>, or 'current'.")
  var pane: String?
  @Argument(parsing: .remaining, help: "Key, or target tab followed by key.")
  var arguments: [String] = []
  @Flag(name: .long, help: "Select the target tab and focus its pane after sending.")
  var focus: Bool = false

  static let discussion = """
    With one positional argument, send the key to the current tab.
    With two positional arguments, the first is the target tab and the
    second is the key name. --tab / --pane name the target instead;
    --pane means that pane's selected tab.

    Named keys are dispatched as ghostty key events so the terminal sees
    the same byte sequences a physical keypress would emit (CSI for
    arrows, 0x1B for escape, 0x09 for tab, and so on).

    Supported keys: escape, up, down, left, right, tab, enter, backspace,
    delete, home, end, pgup, pgdn, f1..f12, ctrl_c, ctrl_d, ctrl_l, ctrl_z.
    """

  func run(globals: GlobalOptions) async throws {
    let explicit = try CLITargetSelection.explicit(tab: tab, pane: pane)
    let (positional, keyName) = try Self.resolveTargetAndKey(arguments: arguments, hasExplicitTarget: explicit != nil)
    let normalised = keyName.lowercased().replacingOccurrences(of: "-", with: "_")
    guard let named = IPC.TerminalNamedKey(rawValue: normalised) else {
      let names = IPC.TerminalNamedKey.allCases.map(\.rawValue).joined(separator: ", ")
      throw CLIError(code: .userError, message: "unknown key \"\(keyName)\". Supported: \(names)")
    }
    let client = CLISession.connect(globals: globals)
    defer { Task { await client.shutdown() } }
    let target = try await TabTarget.resolve(explicit ?? .tab(positional ?? "current"), client: client)
    if focus {
      try await TabTarget.activate(target, client: client)
    }
    struct Params: Codable {
      let contentID: ContentID
      let key: IPC.TerminalNamedKey
    }
    _ = try await client.callRaw(.terminalSendKey, params: Params(contentID: target.contentID, key: named))
    var object = target.jsonFields
    object["key"] = named.rawValue
    try Renderer.emitObject(object, mode: globals.renderMode) { obj in
      "sent \(obj["key"] ?? "?") to tab \(target.tabID)"
    }
  }

  /// One positional = key (target is the explicit one or the current
  /// tab); two = `<tab> <key>`, only without an explicit target.
  static func resolveTargetAndKey(arguments: [String], hasExplicitTarget: Bool) throws -> (String?, String) {
    switch (arguments.count, hasExplicitTarget) {
    case (1, _): return (nil, arguments[0])
    case (0, _): throw CLIError(code: .userError, message: "missing key name")
    case (2, false): return (arguments[0], arguments[1])
    case (_, true):
      throw CLIError(
        code: .userError, message: "expected one positional key when --tab / --pane is set, got \(arguments.count)")
    default:
      throw CLIError(
        code: .userError,
        message: "expected <key> or <tab> <key>, got \(arguments.count) positional arguments")
    }
  }
}

struct TabSendKey: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "send-key", abstract: "Send a named special key to a tab.", discussion: SendKeyOptions.discussion)

  @OptionGroup var globals: GlobalOptions
  @OptionGroup var options: SendKeyOptions

  func run() async throws {
    await CommandRunner.run(self, globals: globals) { try await options.run(globals: globals) }
  }
}

struct SendKeyCommand: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "send-key", abstract: "Send a named special key to a tab (same as `tab send-key`).",
    discussion: SendKeyOptions.discussion)

  @OptionGroup var globals: GlobalOptions
  @OptionGroup var options: SendKeyOptions

  func run() async throws {
    await CommandRunner.run(self, globals: globals) { try await options.run(globals: globals) }
  }
}

struct CaptureOptions: ParsableArguments {
  enum Scope: String, ExpressibleByArgument {
    case viewport
    case screen
  }

  @Argument(help: "Tab: an id (pane, tab, or content), t<n>, @label, or 'current' (default).")
  var target: String?
  @Option(name: [.customShort("t"), .long], help: "Target tab, as the positional.")
  var tab: String?
  @Option(name: [.customShort("p"), .long], help: "Target pane (its selected tab): an id, p<n>, or 'current'.")
  var pane: String?
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

  static let discussion = """
    Plain-text snapshot of what's currently rendered in the tab. Reads
    the visible viewport by default; pass --scope screen for the whole
    active screen buffer (scrolled-off rows included). --pane captures
    that pane's selected tab.

    Use --lines=N to keep only the last N non-empty trailing lines.

    Pass --wait-stable to poll the tab until its rendered text stops
    changing before capturing — useful after firing a command or agent
    to wait for it to actually settle instead of a fixed sleep. Tune with
    --stable-ms (quiet window, default 500), --interval-ms (poll cadence,
    default 100), and --timeout-ms (overall cap, default 5000). In --json
    mode the result carries stabilized / waitedMs / samples; keep
    --timeout-ms below the client --timeout (default 10s).

    Raw ANSI byte stream capture (OSC/CSI/APC) is not supported —
    libghostty exposes parsed text only; `tab read --raw` returns the
    terminal daemon's vt-format dump instead.
    """

  func run(globals: GlobalOptions) async throws {
    struct WaitStablePayload: Codable {
      let stableMillis: Int
      let intervalMillis: Int
      let timeoutMillis: Int
    }
    struct Params: Codable {
      let contentID: ContentID
      let extent: String
      let waitStable: WaitStablePayload?
    }
    struct Result: Codable {
      let text: String
      let stabilized: Bool?
      let waitedMillis: Int?
      let samples: Int?
    }
    let selection = try CLITargetSelection.resolve(tab: tab, pane: pane, positional: target)
    if let lines, lines <= 0 {
      throw CLIError(code: .userError, message: "--lines must be a positive integer")
    }
    var wait: WaitStablePayload?
    if waitStable {
      guard stableMs > 0, intervalMs > 0, timeoutMs > 0 else {
        throw CLIError(
          code: .userError, message: "--stable-ms, --interval-ms, and --timeout-ms must be positive")
      }
      guard Double(timeoutMs) / 1000.0 < globals.timeout else {
        throw CLIError(
          code: .userError,
          message:
            "--timeout-ms (\(timeoutMs)ms) must be below the client --timeout (\(globals.timeout)s); raise --timeout")
      }
      wait = WaitStablePayload(stableMillis: stableMs, intervalMillis: intervalMs, timeoutMillis: timeoutMs)
    }
    let client = CLISession.connect(globals: globals)
    defer { Task { await client.shutdown() } }
    let resolved = try await TabTarget.resolve(selection, client: client)
    let result: Result = try await client.call(
      .terminalReadText,
      params: Params(contentID: resolved.contentID, extent: scope.rawValue, waitStable: wait)
    )
    let trimmed = Self.trim(result.text, lastLines: lines)
    var object = resolved.jsonFields
    object["scope"] = scope.rawValue
    object["lines"] = trimmed.lineCount
    object["text"] = trimmed.text
    if waitStable {
      object["stabilized"] = result.stabilized ?? false
      object["waitedMs"] = result.waitedMillis ?? 0
      object["samples"] = result.samples ?? 0
    }
    try Renderer.emitObject(object, mode: globals.renderMode) { obj in
      obj["text"] as? String ?? ""
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

struct TabCapture: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "capture", abstract: "Capture a tab's rendered text.", discussion: CaptureOptions.discussion)

  @OptionGroup var globals: GlobalOptions
  @OptionGroup var options: CaptureOptions

  func run() async throws {
    await CommandRunner.run(self, globals: globals) { try await options.run(globals: globals) }
  }
}

struct CaptureCommand: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "capture", abstract: "Capture a tab's rendered text (same as `tab capture`).",
    discussion: CaptureOptions.discussion)

  @OptionGroup var globals: GlobalOptions
  @OptionGroup var options: CaptureOptions

  func run() async throws {
    await CommandRunner.run(self, globals: globals) { try await options.run(globals: globals) }
  }
}

struct BroadcastCommand: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "broadcast",
    abstract: "Send text to every tab of a pane, a worktree, or a label."
  )

  @OptionGroup var globals: GlobalOptions
  @Option(name: .long, help: "Pane id (or a tab / content id: its pane), p<n>, or 'current'.")
  var pane: String?
  @Option(name: .long, help: "Worktree id, name, branch, or 'current'.")
  var worktree: String?
  @Option(name: .long, help: "Tab label.")
  var label: String?
  @Argument(parsing: .remaining, help: "Text to send.")
  var text: [String] = []
  @Flag(name: .long, help: "Read text from stdin.")
  var stdin: Bool = false
  @Flag(name: .long, help: "Do not send trailing Enter after text.")
  var noEnter: Bool = false

  func run() async throws {
    await CommandRunner.run(self, globals: globals) {
      if stdin && !text.isEmpty {
        throw CLIArgumentError.conflictingTextSources
      }
      let payload = try CLICommandText.resolve(
        pieces: text,
        stdin: stdin ? try StandardInput.readString() : nil,
        readsStdin: stdin
      )
      let submitted = CLICommandText.appendEnterIfNeeded(payload, noEnter: noEnter)
      let selected = try CLIBroadcastScopeSelection.resolve(pane: pane, worktree: worktree, label: label)
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
        "broadcast \(obj["bytes"] ?? 0) bytes to \(obj["delivered"] ?? 0) tab(s)"
      }
    }
  }

  private func resolveScope(
    _ selection: CLIBroadcastScopeSelection,
    client: RPCClient
  ) async throws -> IPC.BroadcastScope {
    switch selection {
    case .pane(let value):
      let uuid = try await AliasResolver.resolve(value, kind: .pane, client: client)
      return .pane(PaneID(raw: uuid))
    case .worktree(let value):
      let uuid = try await AliasResolver.resolve(value, kind: .worktree, client: client)
      return .worktree(WorktreeID(raw: uuid))
    case .label(let value):
      return .label(value)
    }
  }
}

import CodansIPC
import CodansRemote
import ComposableArchitecture
import Foundation
import Network

/// A self-contained Mac for screenshots and design review: launched with
/// `CODANS_DEMO=1`, the app talks to fixture dependencies instead of the
/// network — a paired gateway, a hierarchy with a split tab, agent states
/// and terminal streams fed with canned TUI bytes. Debug builds only.
///
/// - `CODANS_DEMO_PANE`: the pane to open (`claude`, `shell`, `server`,
///   `build`), or `none` to stay on the home screen.
/// - `CODANS_DEMO_RECONNECT=1`: the connection drops two seconds in and
///   never comes back, to show the reconnecting states; `backoff` fails
///   each attempt at once instead, to show the countdown between attempts.
/// - `CODANS_DEMO_READONLY=1`: the Mac grants read-only access.
/// - `CODANS_DEMO_NOT_OPEN=1`: keys answer "pane not open on the Mac".
/// - `CODANS_DEMO_EXITED=1`: the pane's process exits right after its
///   first screen, to show the exited banner.
/// - `CODANS_DEMO_FAILURE`: the Mac never connects, to show a failure state:
///   `notFound` (no advertisement), `rejected` (every handshake refused),
///   `denied` (Local Network access off) or `offline` (never answers, with
///   a cached workspace from an hour ago shown as stale).
///   Also `incompatible` (the Mac speaks another protocol major) and
///   `slow` (the first connection never finishes, with no cache: the
///   first-load skeleton).
/// - `CODANS_DEMO_SHEET`: open `agents`, `settings`, `pairing`,
///   `connectionDetails` or `composer` shortly after launch.
/// - `CODANS_DEMO_BUSY=1`: the claude pane is a wide Mac pane (170 × 48)
///   under a busy agent — a spinner redrawn every 60 ms and a new line of
///   output every 300 ms — for measuring the terminal's rendering cost.
/// - `CODANS_DEMO_APPROXIMATE=1`: streams arrive as from a pane started
///   before the observer protocol, marked approximate.
/// - `CODANS_DEMO_OLD_MAC=1`: the Mac speaks protocol minor 1, so panes use
///   the text fallback and ask for a Mac update.
///
/// Outside demo mode, `CODANS_FORCE_KEY_BAR=1` keeps the key bar up while a
/// hardware keyboard is attached (see `forcesKeyBar`).
enum DemoMode {
  #if DEBUG
    static let isEnabled = ProcessInfo.processInfo.environment["CODANS_DEMO"] == "1"
  #else
    static let isEnabled = false
  #endif

  /// The simulator usually has the Mac's keyboard attached, which would
  /// hide the key bar in every screenshot, and from UI tests against a real
  /// Mac, which launch with `CODANS_FORCE_KEY_BAR=1` to reach it.
  static var forcesKeyBar: Bool {
    #if DEBUG
      isEnabled || ProcessInfo.processInfo.environment["CODANS_FORCE_KEY_BAR"] == "1"
    #else
      false
    #endif
  }

  /// UI tests against a real Mac on the same network launch with
  /// `CODANS_FORCE_RELAY=1` to skip Bonjour and take the relay route.
  nonisolated static var forcesRelay: Bool {
    #if DEBUG
      ProcessInfo.processInfo.environment["CODANS_FORCE_RELAY"] == "1"
    #else
      false
    #endif
  }

  static var initialSheet: String? {
    guard isEnabled else { return nil }
    return ProcessInfo.processInfo.environment["CODANS_DEMO_SHEET"]
  }

  static var initialSelection: (worktreeID: String, paneID: String)? {
    guard isEnabled else { return nil }
    let pane = ProcessInfo.processInfo.environment["CODANS_DEMO_PANE"] ?? "claude"
    guard pane != "none" else { return nil }
    return (DemoFixtures.worktreeID, DemoFixtures.paneID(pane))
  }
}

#if DEBUG
  extension DemoMode {
    private static var environment: [String: String] { ProcessInfo.processInfo.environment }

    /// Overrides every dependency that would reach the network or the
    /// Keychain.
    static func apply(to dependencies: inout DependencyValues) {
      let gateway = DemoFixtures.gateway
      dependencies.pairingStore = PairingStore(
        load: { PairingStore.Snapshot(gateways: [gateway], activeID: gateway.deviceID) },
        save: { payload, date in PairedGateway(payload: payload, pairedAt: date) },
        remove: { _ in },
        setActive: { _ in },
        setRelay: { _, _ in },
        credential: { _ in RemoteTLS.PSKCredential(identity: "demo", key: Data(repeating: 1, count: 32)) }
      )
      dependencies.networkPath = NetworkPathClient(changes: { AsyncStream { _ in } })
      dependencies.remoteClient = client
      dependencies.workspaceCache = cache
    }

    private static var failure: String? { environment["CODANS_DEMO_FAILURE"] }

    /// Only the `offline` scenario has a cache; the others start empty so
    /// their placeholders show.
    private static var cache: WorkspaceCacheClient {
      guard failure == "offline" else { return .empty }
      return WorkspaceCacheClient(
        load: { _ in
          CachedWorkspace(
            savedAt: Date().addingTimeInterval(-3600), protocolMinor: 2, hierarchy: DemoFixtures.hierarchy,
            agents: DemoFixtures.agents)
        },
        save: { _, _ in },
        remove: { _ in }
      )
    }

    /// One instance for every store: pane stores are created by views and
    /// take their dependencies from here too.
    private static let client = makeClient()

    /// Discovery per failure scenario; without one the Mac is found at once.
    nonisolated private static func discover(_ gateway: PairedGateway, failure: String?) async throws -> [NWEndpoint] {
      switch failure {
      case "notFound"?:
        try await Task.sleep(for: .seconds(1))
        throw RemoteFailure.macNotFound(gateway.displayName)
      case "denied"?:
        throw RemoteFailure(.localNetworkDenied, "Local Network access is off for Codans.")
      case "incompatible"?:
        throw RemoteFailure(.incompatible, "This Mac speaks a newer protocol than this app.")
      case "offline"?, "slow"?:
        // Never answers: the attempt runs into its deadline and retries.
        try await Task.sleep(for: .seconds(3600))
        return []
      default:
        return []
      }
    }

    private static func makeClient() -> RemoteClient {
      let reconnect = environment["CODANS_DEMO_RECONNECT"]
      let dropsConnection = reconnect == "1" || reconnect == "backoff"
      let failsFast = reconnect == "backoff"
      let readOnly = environment["CODANS_DEMO_READONLY"] == "1"
      let notOpen = environment["CODANS_DEMO_NOT_OPEN"] == "1"
      let exits = environment["CODANS_DEMO_EXITED"] == "1"
      let busy = environment["CODANS_DEMO_BUSY"] == "1"
      let fidelity: IPC.TerminalStreamFidelity =
        environment["CODANS_DEMO_APPROXIMATE"] == "1" ? .approximate : .exact
      let protocolMinor = environment["CODANS_DEMO_OLD_MAC"] == "1" ? 1 : 2
      let failure = failure
      let connects = LockIsolated(0)
      return RemoteClient(
        discover: { try await discover($0, failure: failure) },
        connect: { _, _, _ in
          if failure == "rejected" { throw RemoteFailure.refused }
          let attempt = connects.withValue { value -> Int in
            value += 1
            return value
          }
          if failsFast, attempt > 1 {
            // Refuses at once: the app waits out growing backoff delays.
            try await Task.sleep(for: .milliseconds(300))
            throw RemoteFailure.streamEnded
          }
          if dropsConnection, attempt > 1 {
            // Never answers: the app stays in its reconnecting state.
            try await Task.sleep(for: .seconds(3600))
          }
          let events = AsyncThrowingStream<IPC.EventFrame, Error> { continuation in
            continuation.yield(
              IPC.EventFrame(
                seq: 1,
                payload: .snapshot(
                  IPC.EventsSnapshot(hierarchy: DemoFixtures.hierarchy, agents: DemoFixtures.agents))))
            let task = Task {
              if dropsConnection {
                try? await Task.sleep(for: .seconds(2))
                continuation.finish(throwing: RemoteFailure.streamEnded)
                return
              }
              var seq = 2
              while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(20))
                continuation.yield(IPC.EventFrame(seq: seq, payload: .heartbeat))
                seq += 1
              }
            }
            continuation.onTermination = { _ in task.cancel() }
          }
          return RemoteSession(
            info: RemoteSessionInfo(
              serverVersion: "0.9.0", permission: readOnly ? .readOnly : .interactive,
              protocolMinor: protocolMinor),
            events: events)
        },
        // The demo gateway has no relay.
        connectRelay: { gateway, _ in throw RemoteFailure.macNotFound(gateway.displayName) },
        disconnect: {},
        readPane: { paneID, _ in DemoFixtures.text(for: paneID) },
        sendInput: { _, _ in },
        sendKey: { _, _ in },
        listProfiles: { DemoFixtures.profiles },
        createWorktree: { _, _ in DemoFixtures.worktreeID },
        launchAgent: { _, _, _, _ in nil },
        attachStream: { paneID, _, _ in
          AsyncThrowingStream { continuation in
            var sample = DemoFixtures.stream(for: paneID)
            let isBusy = busy && paneID == DemoFixtures.paneID("claude")
            if isBusy { sample = DemoFixtures.Sample(cols: 170, rows: 48, bytes: sample.bytes) }
            continuation.yield(
              IPC.TerminalStreamFrame(
                seq: 1, epoch: 1, payload: .reset(cols: sample.cols, rows: sample.rows, fidelity: fidelity)))
            continuation.yield(IPC.TerminalStreamFrame(seq: 2, epoch: 1, payload: .output(sample.bytes)))
            if exits {
              continuation.yield(
                IPC.TerminalStreamFrame(seq: 3, epoch: 1, payload: .exited(reason: "exit status 1", exitCode: 1)))
            }
            let task = Task {
              if isBusy {
                await DemoFixtures.streamBusyAgent(from: 3, into: continuation)
              } else {
                await DemoFixtures.streamHeartbeats(from: 3, into: continuation)
              }
            }
            continuation.onTermination = { _ in task.cancel() }
          }
        },
        setSeatSize: { _, _ in },
        claimSize: { _, _ in },
        typeBytes: { _, _ in },
        sendEvents: { _, events in
          if notOpen { throw RemoteFailure(.unsupported, "pane not open on the Mac") }
          return IPC.TerminalSendEventsResult(delivered: events.count, rejected: [])
        },
        createTab: { _, _ in DemoFixtures.paneID("build") },
        splitPane: { _, _ in DemoFixtures.paneID("server") },
        renameTab: { _, _ in },
        closeTab: { _ in },
        closePane: { _ in },
        activateTab: { _ in }
      )
    }
  }
#endif

/// The demo Mac's contents.
nonisolated enum DemoFixtures {
  static let projectID = "D0000000-0000-0000-0000-000000000001"
  static let worktreeID = "D0000000-0000-0000-0000-000000000002"
  static let mainWorktreeID = "D0000000-0000-0000-0000-000000000003"
  static let agentTabID = "D0000000-0000-0000-0000-000000000010"
  static let buildTabID = "D0000000-0000-0000-0000-000000000011"

  static func paneID(_ name: String) -> String {
    switch name {
    case "shell": return "D0000000-0000-0000-0000-000000000102"
    case "server": return "D0000000-0000-0000-0000-000000000103"
    case "build": return "D0000000-0000-0000-0000-000000000104"
    case "main": return "D0000000-0000-0000-0000-000000000105"
    default: return "D0000000-0000-0000-0000-000000000101"
    }
  }

  static let gateway = PairedGateway(
    deviceID: UUID(uuidString: "D0000000-0000-0000-0000-0000000000FF")!,
    serviceName: "Studio Mac (codans-dev)",
    channel: "codans-dev",
    pskIdentity: "demo",
    pairedAt: Date(timeIntervalSince1970: 1_790_000_000))

  static let profiles = [
    IPC.AgentProfileSummary(
      id: UUID(), name: "Claude Code", agent: "claude-code", agentName: "Claude Code", isEnabled: true,
      isInstalled: true, supportsPrompt: true, command: "claude")
  ]

  static var hierarchy: IPC.HierarchySummary {
    let cwd = "/Users/gump/dev/codans"
    let agentTab = IPC.TabSummary(
      id: agentTabID, handle: "t1", title: "agent", focusedPaneID: paneID("claude"),
      panes: [
        IPC.PaneSummary(
          id: paneID("claude"), handle: "p1", title: "Claude Code", agent: "claude-code", labels: [], cwd: cwd,
          isLive: true),
        IPC.PaneSummary(
          id: paneID("shell"), handle: "p2", title: "zsh", agent: nil, labels: [], cwd: cwd, isLive: true),
        IPC.PaneSummary(
          id: paneID("server"), handle: "p3", title: "vite", agent: nil, labels: [], cwd: cwd + "/web", isLive: true),
      ],
      layout: .split(
        direction: .horizontal, ratio: 0.58,
        left: .leaf(paneID: paneID("claude")),
        right: .split(
          direction: .vertical, ratio: 0.5, left: .leaf(paneID: paneID("shell")),
          right: .leaf(paneID: paneID("server")))))
    let buildTab = IPC.TabSummary(
      // A shell's own title, as long as they come.
      id: buildTabID, handle: "t2", title: "gump@Gumps-MacBook-Pro:~/dev/codans/apps/ios",
      focusedPaneID: paneID("build"),
      panes: [
        IPC.PaneSummary(
          id: paneID("build"), handle: "p4", title: "make ios-build", agent: nil, labels: [], cwd: cwd, isLive: true)
      ],
      layout: .leaf(paneID: paneID("build")))
    let mainTab = IPC.TabSummary(
      id: "D0000000-0000-0000-0000-000000000012", handle: "t3", title: "codex", focusedPaneID: paneID("main"),
      panes: [
        IPC.PaneSummary(
          id: paneID("main"), handle: "p5", title: "Codex", agent: "codex", labels: [], cwd: cwd, isLive: true)
      ])
    return IPC.HierarchySummary(
      projects: [
        IPC.ProjectSummary(
          id: projectID, name: "codans", isRemote: false, selectedWorktreeID: worktreeID,
          worktrees: [
            IPC.WorktreeSummary(
              id: worktreeID, name: "feat/ios", branch: "feat/ios", isPinned: false, selectedTabID: agentTabID,
              tabs: [agentTab, buildTab]),
            IPC.WorktreeSummary(
              id: mainWorktreeID, name: "main", branch: "main", isPinned: true, selectedTabID: mainTab.id,
              tabs: [mainTab]),
          ])
      ],
      selectedProjectID: projectID,
      activePaneID: paneID("claude"))
  }

  static var agents: [IPC.AgentStateEntry] {
    [
      entry(paneID("claude"), agent: "claude-code", name: "Claude Code", state: "working", worktree: worktreeID),
      entry(paneID("main"), agent: "codex", name: "Codex", state: "blocked", worktree: mainWorktreeID),
    ]
  }

  private static func entry(
    _ paneID: String, agent: String, name: String, state: String, worktree: String
  ) -> IPC.AgentStateEntry {
    IPC.AgentStateEntry(
      paneID: paneID, handle: nil, agent: agent, agentName: name, state: state, since: "2026-09-26T08:00:00Z",
      sessionID: nil, title: nil, projectID: projectID, projectName: "codans", worktreeID: worktree,
      worktreeName: worktree == worktreeID ? "feat/ios" : "main", tabID: agentTabID, tabTitle: nil,
      isFocused: false)
  }

  /// A quiet pane: a heartbeat every 30 s, until cancelled.
  static func streamHeartbeats(
    from firstSeq: Int, into continuation: AsyncThrowingStream<IPC.TerminalStreamFrame, Error>.Continuation
  ) async {
    var seq = firstSeq
    while !Task.isCancelled {
      try? await Task.sleep(for: .seconds(30))
      continuation.yield(IPC.TerminalStreamFrame(seq: seq, epoch: 1, payload: .heartbeat))
      seq += 1
    }
  }

  /// A busy agent's output: a spinner redrawn every 60 ms, a new line
  /// every 300 ms, until cancelled.
  static func streamBusyAgent(
    from firstSeq: Int, into continuation: AsyncThrowingStream<IPC.TerminalStreamFrame, Error>.Continuation
  ) async {
    let spinner = ["✻", "✶", "✳", "✢", "·", "✢", "✳", "✶"]
    var seq = firstSeq
    var tick = 0
    while !Task.isCancelled {
      try? await Task.sleep(for: .milliseconds(60))
      var chunk = ""
      if tick % 5 == 0 {
        chunk += "\r\u{1B}[2K  ⎿  Read apps/ios/CodansMobile/Features/Terminal/File\(tick).swift "
        chunk += String(repeating: "lorem ipsum ", count: 10) + "\r\n"
      }
      chunk += "\r\u{1B}[2K\u{1B}[38;5;208m\(spinner[tick % spinner.count]) Working… "
      chunk += "(\(tick * 60 / 1000)s · esc to interrupt)\u{1B}[0m"
      continuation.yield(IPC.TerminalStreamFrame(seq: seq, epoch: 1, payload: .output(Data(chunk.utf8))))
      seq += 1
      tick += 1
    }
  }

  struct Sample {
    let cols: Int
    let rows: Int
    let bytes: Data
  }

  static func stream(for paneID: String) -> Sample {
    switch paneID {
    case self.paneID("shell"): return Sample(cols: 64, rows: 20, bytes: Data(DemoTerminalSamples.shell.utf8))
    case self.paneID("server"): return Sample(cols: 64, rows: 20, bytes: Data(DemoTerminalSamples.server.utf8))
    case self.paneID("build"): return Sample(cols: 96, rows: 34, bytes: Data(DemoTerminalSamples.build.utf8))
    default:
      return Sample(cols: 96, rows: 34, bytes: Data(DemoTerminalSamples.claudeCode(cols: 96).utf8))
    }
  }

  /// The same sample as `pane.read` would return it: plain text, escape
  /// sequences stripped.
  static func text(for paneID: String) -> String {
    let raw = String(bytes: stream(for: paneID).bytes, encoding: .utf8) ?? ""
    return raw.replacingOccurrences(of: "\u{1B}\\[[0-9;?]*[A-Za-z]", with: "", options: .regularExpression)
      .replacingOccurrences(of: "\r", with: "")
  }
}

/// Canned terminal output: what an agent TUI, a shell and a dev server
/// look like on the Mac.
nonisolated enum DemoTerminalSamples {
  private static let esc = "\u{1B}"

  private static func sgr(_ codes: String, _ text: String) -> String {
    "\(esc)[\(codes)m\(text)\(esc)[0m"
  }

  static func claudeCode(cols: Int) -> String {
    let accent = "38;2;215;119;87"
    let dim = "38;5;245"
    let rule = String(repeating: "─", count: cols - 2)
    var lines: [String] = []
    // Pads by visible characters so the right border lines up.
    func boxed(_ plain: String, _ styled: String) -> String {
      sgr(accent, "│") + styled + String(repeating: " ", count: max(0, 48 - plain.count)) + sgr(accent, "│")
    }
    lines.append(sgr(accent, "╭" + String(repeating: "─", count: 48) + "╮"))
    lines.append(
      boxed(" ✻ Welcome to Claude Code!", " " + sgr(accent, "✻") + " Welcome to " + sgr("1", "Claude Code") + "!"))
    lines.append(boxed("", ""))
    lines.append(
      boxed("   /help for help, /status for your setup", sgr(dim, "   /help for help, /status for your setup")))
    lines.append(boxed("   cwd: ~/dev/codans", sgr(dim, "   cwd: ~/dev/codans")))
    lines.append(sgr(accent, "╰" + String(repeating: "─", count: 48) + "╯"))
    lines.append("")
    lines.append(sgr(dim, "> ") + "Add a live terminal to the iOS app that mirrors the Mac pane")
    lines.append("")
    lines.append(sgr(accent, "⏺") + " I'll start with the stream reducer, then the key bar.")
    lines.append("")
    lines.append(
      sgr(accent, "⏺") + " " + sgr("1", "Read")
        + "(apps/ios/CodansMobile/Features/Terminal/TerminalStreamFeature.swift)")
    lines.append("  " + sgr(dim, "⎿  Read 412 lines"))
    lines.append("")
    lines.append(sgr(accent, "⏺") + " " + sgr("1", "Update") + "(TerminalStreamFeature.swift)")
    lines.append("  " + sgr(dim, "⎿  Updated with 6 additions and 2 removals"))
    lines.append("     " + sgr(dim, "212") + "        case .output(let data):")
    lines.append(
      "     " + sgr(dim, "213")
        + sgr("48;2;40;64;40", "+         guard frame.epoch == state.epoch else { return .none }"))
    lines.append(
      "     " + sgr(dim, "214")
        + sgr("48;2;40;64;40", "+         state.screen.feed(data)                              "))
    lines.append(
      "     " + sgr(dim, "215")
        + sgr("48;2;72;36;36", "-         state.buffer.append(data)                            "))
    lines.append("")
    lines.append(sgr(accent, "⏺") + " " + sgr("1", "Bash") + "(make ios-build)")
    lines.append("  " + sgr(dim, "⎿  ** BUILD SUCCEEDED **"))
    lines.append("")
    lines.append(sgr(accent, "✢ Wiring the key bar… ") + sgr(dim, "(38s · ↑ 2.4k tokens · esc to interrupt)"))
    lines.append("")
    lines.append(sgr("38;5;240", "╭" + rule + "╮"))
    lines.append(sgr("38;5;240", "│") + " > " + String(repeating: " ", count: cols - 5) + sgr("38;5;240", "│"))
    lines.append(sgr("38;5;240", "╰" + rule + "╯"))
    lines.append(sgr(dim, "  ⏵⏵ accept edits on (shift+tab to cycle)"))
    return "\(esc)[?1049h\(esc)[?25l\(esc)[2J\(esc)[H" + lines.joined(separator: "\r\n")
  }

  static let shell: String = {
    let prompt = sgr("38;5;110", "~/dev/codans") + " " + sgr("38;5;245", "feat/ios") + " " + sgr("38;5;150", "❯") + " "
    return [
      prompt + "git status --short",
      sgr("32", " M") + " apps/ios/Project.swift",
      sgr("31", "??") + " apps/ios/CodansMobile/Features/Terminal/",
      prompt + "ls apps/ios/CodansMobile/Features",
      sgr("1;34", "Agents") + "  " + sgr("1;34", "Browser") + "  " + sgr("1;34", "Composer") + "  "
        + sgr("1;34", "Connection") + "  " + sgr("1;34", "Terminal"),
      prompt,
    ].joined(separator: "\r\n")
  }()

  static let server: String = [
    sgr("1;32", "  VITE v7.1.4") + "  ready in 412 ms",
    "",
    "  " + sgr("32", "➜") + "  " + sgr("1", "Local:") + "   " + sgr("36", "http://localhost:5173/"),
    "  " + sgr("2", "➜  Network: use --host to expose"),
    "",
    sgr("2", "10:42:07") + " " + sgr("36", "[vite]") + " hmr update " + sgr("2", "/src/App.tsx"),
    sgr("2", "10:42:31") + " " + sgr("36", "[vite]") + " page reload " + sgr("2", "index.html"),
  ].joined(separator: "\r\n")

  static let build: String = [
    sgr("38;5;150", "❯") + " make ios-build",
    "tuist generate --no-open",
    sgr("32", "✔ Success"),
    "  Project generated.",
    "xcodebuild -workspace CodansMobile.xcworkspace -scheme CodansMobile build",
    sgr("2", "CompileSwift normal arm64 TerminalStreamFeature.swift"),
    sgr("2", "CompileSwift normal arm64 TerminalKeyBar.swift"),
    sgr("2", "Ld Codans.app/Codans normal"),
    sgr("1;32", "** BUILD SUCCEEDED **"),
  ].joined(separator: "\r\n")
}

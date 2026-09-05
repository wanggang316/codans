import Foundation

/// Every environment variable codans reads or writes, spelled once.
///
/// The names cross three process boundaries — the app writes into panes,
/// the CLI reads inside them, tests and dev flows set overrides — and each
/// boundary used to carry its own literal. A typo in one silently broke the
/// contract for the other side with nothing failing to compile. Each case
/// says who writes it, who reads it, and how long it lives, so the contract
/// is legible without grepping.
public nonisolated enum CodansEnvironment {
  public enum Key: String, CaseIterable, Sendable {
    // MARK: Injected into every pane by the app

    /// This app's IPC socket. Written last so a project's own `envVars`
    /// cannot shadow it. The CLI inside the pane dials it; a codans *app*
    /// launched from the pane discards it when it names the other channel
    /// (see `SocketPaths.resolve`).
    case socketPath = "CODANS_SOCKET_PATH"
    /// The pane's own id. Stable for the pane's whole life, so it is safe to
    /// bake into the environment at spawn — unlike its tab or worktree,
    /// which change when the pane is moved and are therefore resolved
    /// server-side from process ancestry instead. The CLI's `current`
    /// pronoun reads it first.
    case paneID = "CODANS_PANE_ID"
    /// Absolute worktree root. User-facing: pinned as a read-only row in the
    /// Environment editor, which refuses a user key of the same name.
    case worktreePath = "CODANS_WORKTREE_PATH"
    /// Absolute root of the Project the worktree came from. User-facing,
    /// like `worktreePath`.
    case rootPath = "CODANS_ROOT_PATH"
    /// Where zmx keeps its per-pane daemon sockets — this channel's cache
    /// directory, pinned so the reaper and the control client look in the
    /// same place zmx writes to.
    case zmxDirectory = "ZMX_DIR"
    /// Cleared (set to empty) for every pane. An app launched from inside a
    /// zmx pane inherits the parent's session name, and `zmx attach` would
    /// read it as "switch to that session" and fail because it lives in
    /// another `ZMX_DIR`.
    case zmxSession = "ZMX_SESSION"
    /// Product marker for shells and TUIs. Written last, like the socket.
    case termProgram = "TERM_PROGRAM"
    /// The app's marketing version, next to `termProgram`.
    case termProgramVersion = "TERM_PROGRAM_VERSION"

    // MARK: Read by the CLI's `current` pronoun

    /// Read only; nothing in the app injects these. A caller that exports
    /// one by hand short-circuits the server round trip for that kind.
    case projectID = "CODANS_PROJECT_ID"
    case worktreeID = "CODANS_WORKTREE_ID"
    case tabID = "CODANS_TAB_ID"
    case tagID = "CODANS_TAG_ID"

    // MARK: Overrides and seams read at startup

    /// Relocates the whole config root — every JSON store — so a smoke or
    /// integration run never touches the user's real `~/.config/<slug>/`.
    case configDirectory = "CODANS_CONFIG_DIR"
    /// Points the CLI installer at a freshly built `codans` outside the
    /// `.app`, for dev.
    case cliBinary = "CODANS_CLI_BINARY"
    /// Alternative root for libghostty's resources tree when the bundle has
    /// none — unbundled `xcodebuild run` flows.
    case ghosttyResources = "CODANS_GHOSTTY_RESOURCES"
    /// `"1"` bypasses libghostty action routing. Diagnostic only.
    case disableActionRouting = "CODANS_DISABLE_ACTION_ROUTING"
    /// `"1"` stops the theme catalog falling back to the developer
    /// worktree's `.build/ghostty` tree, so "empty catalog" tests hold.
    case disableThemeDevFallback = "CODANS_DISABLE_THEME_DEV_FALLBACK"

    // MARK: One-shot, per request

    /// Prefixed onto the shell command the Hand Off panel asks the source
    /// agent to run, so the handler can prove the transition is the one the
    /// panel is waiting on. Interactive use never sets it.
    case handoffRequestID = "CODANS_HANDOFF_REQUEST_ID"

    // MARK: Third-party keys codans sets process-wide or reads

    /// Exported by `GhosttyBootstrap` before `ghostty_init`; libghostty and
    /// the theme catalog both read it.
    case ghosttyResourcesDirectory = "GHOSTTY_RESOURCES_DIR"
    /// Exported alongside `ghosttyResourcesDirectory` so `xterm-ghostty`
    /// resolves inside panes.
    case terminfoDirectories = "TERMINFO_DIRS"
    /// Honoured when locating the user's Ghostty config and themes.
    case xdgConfigHome = "XDG_CONFIG_HOME"
  }

  /// Terminal-describing keys stripped from the inherited environment before
  /// a pane spawns, so libghostty's own PTY-time values (`TERM=xterm-ghostty`,
  /// `TERM_PROGRAM=codans`) are what the shell sees. When the app is
  /// launched from a non-interactive context — `make` → `open`, an IDE's
  /// build shell — the parent's `TERM=dumb` would otherwise flow through and
  /// break starship and other TUIs.
  public static let inheritedTerminalKeysToStrip: [String] = [
    "TERM", "TERMCAP", "TERMINFO", "COLORTERM",
    Key.termProgram.rawValue, Key.termProgramVersion.rawValue,
  ]
}

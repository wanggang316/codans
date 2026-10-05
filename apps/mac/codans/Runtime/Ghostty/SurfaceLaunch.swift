import Foundation

/// How a pane's surface starts its child process — the two shapes in
/// docs/design-docs/pane-shell-integration.md.
nonisolated enum SurfaceLaunch: Equatable, Sendable {
  /// No `command`: libghostty resolves the user's shell (honouring their
  /// Ghostty `command` / `shell-integration` config), injects shell
  /// integration and applies the macOS login(1) wrapping, then prepends
  /// `wrapper` — `zmx attach <session>` — so the resolved shell becomes the
  /// zmx session's program.
  case interactive(wrapper: [String])
  /// A fixed shell command string (libghostty runs it as `/bin/sh -c`),
  /// with shell integration off for this surface: the command is not a
  /// user shell to integrate.
  case command(String)

  /// `ghostty_surface_config_s.command`; nil leaves libghostty to resolve
  /// the shell.
  var command: String? {
    switch self {
    case .interactive: nil
    case .command(let command): command
    }
  }

  /// `ghostty_surface_config_s.command_wrapper`.
  var wrapper: [String] {
    switch self {
    case .interactive(let wrapper): wrapper
    case .command: []
    }
  }

  /// Always true. libghostty only turns `wait-after-command` on by itself
  /// when `command` is set; without it a shell that exits would close the
  /// surface on its own, bypassing the pane's exit handling, which keys on
  /// `childExited` while the surface stays up.
  var waitsAfterCommand: Bool { true }

  /// `ghostty_surface_config_s.disable_shell_integration`.
  var disablesShellIntegration: Bool {
    switch self {
    case .interactive: false
    case .command: true
    }
  }
}

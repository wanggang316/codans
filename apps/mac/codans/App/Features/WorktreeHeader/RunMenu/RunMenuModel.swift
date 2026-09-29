import AppKit
import CodansCore

/// Everything the Run dropdown shows, rebuilt each time it opens so run
/// state, scripts and scan results are always current.
struct RunMenuModel {
  /// A saved Project or Global command.
  struct Command {
    let id: UUID
    let title: String
    /// Second line: the command it runs, so same-named commands (and every
    /// row) read at the same two-line height.
    let subtitle: String
    let icon: CommandIconRef
    let tint: NSColor
    /// Display-only accelerator (`⌘R`); live dispatch belongs to the menu bar.
    let chord: String?
    let perform: () -> Void
  }

  /// One manifest's detected commands, shown as a submenu.
  struct ConfigFile {
    /// Path relative to the worktree (`apps/web/package.json`).
    let title: String
    let icon: CommandIconRef?
    let entries: [Entry]
  }

  /// A detected command: the row runs it, the trailing accessory adds it.
  struct Entry {
    let id: String
    let title: String
    let subtitle: String
    let icon: CommandIconRef
    let tint: NSColor
    let isAdded: Bool
    let run: () -> Void
    let add: () -> Void
  }

  var projectCommands: [Command] = []
  var globalCommands: [Command] = []
  var configFiles: [ConfigFile] = []
  var isScanning = false
  var refresh: (() -> Void)?
  var manageProjectCommands: () -> Void = {}
  var manageGlobalCommands: () -> Void = {}
}

/// Glyph size shared by the Run button and its dropdown rows, so a command's
/// icon reads the same size inside the menu as on the button that opened it.
enum RunMenuMetrics {
  static let iconPointSize: CGFloat = 13
  static let iconBox: CGFloat = 16
  /// Two-line rows (name, then command), for saved commands and detected
  /// entries alike.
  static let rowHeight: CGFloat = 36
}

import Foundation
import CodansCore

/// The built-in editor registry. Every row is a template: `appURL` is always nil and
/// `alternateBundleIdentifiers` is always empty — the service layer resolves a live `appURL`
/// against an `AppLauncher` at `describe()` time.
///
/// Ordering matters:
/// - `registry` order is stable for snapshot tests and debug output.
/// - `editorPriority` / `terminalPriority` / `gitClientPriority` are the per-category auto-pick
///   orders. `defaultPriority` is the concatenated chain walked on every resolve when no
///   explicit preference is set; it always terminates at Finder (always installed).
/// - `menuOrder` drives the Settings-pane dropdown rendering, including `.editor` at the tail.
///
/// Adding a new entry is a two-line change (registry row + priority insertion).
nonisolated enum EditorRegistry {
  /// Canonical ID for the Finder built-in — always installed, the ultimate fallback in every
  /// resolution chain.
  static let finderID: EditorID = "finder"

  /// Canonical ID for the `$EDITOR` shell pseudo-editor — always available as long as the
  /// Pane primitive (Pane at path + `$EDITOR\n` stdin) is wired.
  static let shellEditorID: EditorID = "editor"

  static let registry: [EditorDescriptor] = [
    // Editors — .directory
    EditorDescriptor(
      id: "cursor", displayName: "Cursor",
      bundleIdentifier: "com.todesktop.230313mzl4w4u92",
      launchMode: .directory, appURL: nil,
      alternateBundleIdentifiers: []),
    EditorDescriptor(
      id: "zed", displayName: "Zed",
      bundleIdentifier: "dev.zed.Zed",
      launchMode: .directory, appURL: nil,
      alternateBundleIdentifiers: []),
    EditorDescriptor(
      id: "vscode", displayName: "Visual Studio Code",
      bundleIdentifier: "com.microsoft.VSCode",
      launchMode: .directory, appURL: nil,
      alternateBundleIdentifiers: []),
    EditorDescriptor(
      id: "windsurf", displayName: "Windsurf",
      bundleIdentifier: "com.exafunction.windsurf",
      launchMode: .directory, appURL: nil,
      alternateBundleIdentifiers: []),
    EditorDescriptor(
      id: "vscodeInsiders", displayName: "VSCode Insiders",
      bundleIdentifier: "com.microsoft.VSCodeInsiders",
      launchMode: .directory, appURL: nil,
      alternateBundleIdentifiers: []),
    EditorDescriptor(
      id: "vscodium", displayName: "VSCodium",
      bundleIdentifier: "com.vscodium",
      launchMode: .directory, appURL: nil,
      alternateBundleIdentifiers: []),
    EditorDescriptor(
      id: "sublimeText", displayName: "Sublime Text",
      bundleIdentifier: "com.sublimetext.4",
      launchMode: .directory, appURL: nil,
      alternateBundleIdentifiers: ["com.sublimetext.3"]),
    // Editors — .applicationWithArguments (JetBrains)
    EditorDescriptor(
      id: "intellij", displayName: "IntelliJ IDEA",
      bundleIdentifier: "com.jetbrains.intellij",
      launchMode: .applicationWithArguments, appURL: nil,
      alternateBundleIdentifiers: []),
    EditorDescriptor(
      id: "webstorm", displayName: "WebStorm",
      bundleIdentifier: "com.jetbrains.WebStorm",
      launchMode: .applicationWithArguments, appURL: nil,
      alternateBundleIdentifiers: []),
    EditorDescriptor(
      id: "pycharm", displayName: "PyCharm",
      bundleIdentifier: "com.jetbrains.pycharm",
      launchMode: .applicationWithArguments, appURL: nil,
      alternateBundleIdentifiers: []),
    EditorDescriptor(
      id: "rubymine", displayName: "RubyMine",
      bundleIdentifier: "com.jetbrains.rubymine",
      launchMode: .applicationWithArguments, appURL: nil,
      alternateBundleIdentifiers: []),
    EditorDescriptor(
      id: "rustrover", displayName: "RustRover",
      bundleIdentifier: "com.jetbrains.rustrover",
      launchMode: .applicationWithArguments, appURL: nil,
      alternateBundleIdentifiers: []),
    EditorDescriptor(
      id: "goland", displayName: "GoLand",
      bundleIdentifier: "com.jetbrains.goland",
      launchMode: .applicationWithArguments, appURL: nil,
      alternateBundleIdentifiers: []),
    EditorDescriptor(
      id: "androidStudio", displayName: "Android Studio",
      bundleIdentifier: "com.google.android.studio",
      launchMode: .applicationWithArguments, appURL: nil,
      alternateBundleIdentifiers: []),
    // Editors — .directory (continued)
    EditorDescriptor(
      id: "antigravity", displayName: "Antigravity",
      bundleIdentifier: "com.google.antigravity",
      launchMode: .directory, appURL: nil,
      alternateBundleIdentifiers: []),
    EditorDescriptor(
      id: "trae", displayName: "Trae",
      bundleIdentifier: "com.trae.app",
      launchMode: .directory, appURL: nil,
      alternateBundleIdentifiers: []),
    EditorDescriptor(
      id: "traeCN", displayName: "Trae CN",
      bundleIdentifier: "cn.trae.app",
      launchMode: .directory, appURL: nil,
      alternateBundleIdentifiers: []),
    EditorDescriptor(
      id: "qoder", displayName: "Qoder",
      bundleIdentifier: "com.qoder.ide",
      launchMode: .directory, appURL: nil,
      alternateBundleIdentifiers: []),
    EditorDescriptor(
      id: "codebuddy", displayName: "CodeBuddy",
      bundleIdentifier: "com.tencent.codebuddy",
      launchMode: .directory, appURL: nil,
      alternateBundleIdentifiers: ["com.tencent.codebuddycn"]),
    // Xcode + Finder
    EditorDescriptor(
      id: "xcode", displayName: "Xcode",
      bundleIdentifier: "com.apple.dt.Xcode",
      launchMode: .directory, appURL: nil,
      alternateBundleIdentifiers: []),
    EditorDescriptor(
      id: "finder", displayName: "Finder",
      bundleIdentifier: "com.apple.finder",
      launchMode: .directory, appURL: nil,
      alternateBundleIdentifiers: []),
    // Terminals
    EditorDescriptor(
      id: "ghostty", displayName: "Ghostty",
      bundleIdentifier: "com.mitchellh.ghostty",
      launchMode: .directory, appURL: nil,
      alternateBundleIdentifiers: []),
    EditorDescriptor(
      id: "wezterm", displayName: "WezTerm",
      bundleIdentifier: "com.github.wez.wezterm",
      launchMode: .directory, appURL: nil,
      alternateBundleIdentifiers: []),
    EditorDescriptor(
      id: "alacritty", displayName: "Alacritty",
      bundleIdentifier: "org.alacritty",
      launchMode: .directory, appURL: nil,
      alternateBundleIdentifiers: []),
    EditorDescriptor(
      id: "kitty", displayName: "Kitty",
      bundleIdentifier: "net.kovidgoyal.kitty",
      launchMode: .directory, appURL: nil,
      alternateBundleIdentifiers: []),
    EditorDescriptor(
      id: "warp", displayName: "Warp",
      bundleIdentifier: "dev.warp.Warp-Stable",
      launchMode: .directory, appURL: nil,
      alternateBundleIdentifiers: []),
    EditorDescriptor(
      id: "terminal", displayName: "Terminal",
      bundleIdentifier: "com.apple.Terminal",
      launchMode: .directory, appURL: nil,
      alternateBundleIdentifiers: []),
    // Git clients
    EditorDescriptor(
      id: "githubDesktop", displayName: "GitHub Desktop",
      bundleIdentifier: "com.github.GitHubClient",
      launchMode: .directory, appURL: nil,
      alternateBundleIdentifiers: []),
    EditorDescriptor(
      id: "sourcetree", displayName: "Sourcetree",
      bundleIdentifier: "com.torusknot.SourceTreeNotMAS",
      launchMode: .directory, appURL: nil,
      alternateBundleIdentifiers: []),
    EditorDescriptor(
      id: "fork", displayName: "Fork",
      bundleIdentifier: "com.DanPristupov.Fork",
      launchMode: .directory, appURL: nil,
      alternateBundleIdentifiers: []),
    EditorDescriptor(
      id: "gitkraken", displayName: "GitKraken",
      bundleIdentifier: "com.axosoft.gitkraken",
      launchMode: .directory, appURL: nil,
      alternateBundleIdentifiers: []),
    EditorDescriptor(
      id: "sublimeMerge", displayName: "Sublime Merge",
      bundleIdentifier: "com.sublimemerge",
      launchMode: .directory, appURL: nil,
      alternateBundleIdentifiers: []),
    EditorDescriptor(
      id: "smartgit", displayName: "SmartGit",
      bundleIdentifier: "com.syntevo.smartgit",
      launchMode: .directory, appURL: nil,
      alternateBundleIdentifiers: []),
    EditorDescriptor(
      id: "gitup", displayName: "GitUp",
      bundleIdentifier: "co.gitup.mac",
      launchMode: .directory, appURL: nil,
      alternateBundleIdentifiers: []),
    // Shell $EDITOR — always installed (no bundle); Pane primitive handles the launch.
    EditorDescriptor(
      id: "editor", displayName: "$EDITOR",
      bundleIdentifier: "",
      launchMode: .shellEditor, appURL: nil,
      alternateBundleIdentifiers: []),
  ]

  // MARK: - Priority lists

  static let editorPriority: [EditorID] = [
    "cursor", "zed", "vscode", "windsurf", "vscodeInsiders", "vscodium", "sublimeText",
    "intellij", "webstorm", "pycharm", "rubymine", "rustrover", "goland", "androidStudio",
    "antigravity", "trae", "traeCN", "qoder", "codebuddy",
  ]

  static let terminalPriority: [EditorID] = [
    "ghostty", "wezterm", "alacritty", "kitty", "warp", "terminal",
  ]

  static let gitClientPriority: [EditorID] = [
    "githubDesktop", "sourcetree", "fork", "gitkraken", "sublimeMerge", "smartgit", "gitup",
  ]

  /// Walk order used by `EditorService.resolve` when no explicit or stored default applies.
  /// Finder sits at the **tail** because it is always installed — if it appeared earlier in
  /// the list, every subsequent ID (terminals, git clients) would be unreachable in auto-
  /// resolution: the priority walk would stop at Finder before reaching Ghostty / GitHub
  /// Desktop / etc. Always terminates at Finder so the walk is guaranteed to resolve.
  static let defaultPriority: [EditorID] =
    editorPriority + ["xcode"] + terminalPriority + gitClientPriority + ["finder"]

  /// Settings-pane dropdown order. Adds `.editor` at the tail since it is installed-by-
  /// definition and therefore never eligible for the priority auto-pick.
  static let menuOrder: [EditorID] =
    editorPriority + ["xcode", "finder"] + terminalPriority + gitClientPriority + ["editor"]
}

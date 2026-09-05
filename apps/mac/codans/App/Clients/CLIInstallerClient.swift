import CodansCore
import Foundation
import os.log

/// Idempotent installer for the codans CLI. Release builds symlink `codans`
/// from `/usr/local/bin/` to the bundled binary inside `codans.app`; Debug
/// builds use `codans-dev` so local development never takes over the
/// production command. The privileged write is a single `do shell script`
/// invocation with admin privileges that runs `mkdir -p` + `ln -s` + legacy
/// cleanup in one transaction. `probe()` is unprivileged and safe to call on
/// view-appear; `install()` / `uninstall()` show the system auth dialog
/// exactly once per call (or zero times when no work remains — the
/// destination is already ours or already absent).
///
/// A foreign file at the destination short-circuits the operation with
/// `.collision(owner:)` and no privileged dialog is shown.
@MainActor
final class CLIInstallerClient {
  /// URLs that parameterise the installer. Tests override everything; production
  /// uses the defaults pointing at `/usr/local/bin`.
  struct Paths: Equatable {
    var tcSymlink: URL
    /// Legacy `~/.local/bin/codans` path from a prior version. The privileged
    /// install script `rm`s it only when it resolves to our bundled binary.
    var legacyLocalBinTc: URL
    /// Bundled `codans` binary to symlink to. Resolved via `CLIBundleLocator`.
    /// `nil` when no bundled binary can be located — install surfaces this
    /// as `.bundleMissing`.
    var bundledTcBinary: URL?

    static var `default`: Paths {
      let home = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
      let usrLocalBin = URL(fileURLWithPath: "/usr/local/bin", isDirectory: true)
      let legacyLocalBin = home.appendingPathComponent(".local/bin", isDirectory: true)
      let tcName = CLIInvocation.commandName
      return Paths(
        tcSymlink: usrLocalBin.appendingPathComponent(tcName, isDirectory: false),
        legacyLocalBinTc: legacyLocalBin.appendingPathComponent(tcName, isDirectory: false),
        bundledTcBinary: try? CLIBundleLocator.locateBinary()
      )
    }

    var primaryCommandName: String { tcSymlink.lastPathComponent }
  }

  /// Current state of the `codans` symlink under `/usr/local/bin/`. Never
  /// persisted; the pane re-`probe()`s on appear.
  enum InstallStatus: Equatable {
    case unknown
    case notInstalled
    /// The symlink is present. `pointsToBundle` is false when it is a codans
    /// symlink that resolves to another build's binary, or to one that no
    /// longer exists — Install replaces it.
    case installed(at: URL, pointsToBundle: Bool)
    /// A file exists at `tcSymlink` that codans did not create. We never
    /// overwrite it.
    case collision(owner: URL)
    case failed(CLIInstallError, lastAttempt: Date?)
  }

  enum CLIInstallError: Error, Equatable {
    case bundleMissing(URL?)
    case destinationExistsNotOurs(URL)
    case userCancelled
    case scriptFailed(stderr: String)
  }

  /// Surfaced so the Developer pane can point at the installed symlink for
  /// "Reveal in Finder". Mutating setters are not needed — callers pass a
  /// different `Paths` through the initializer.
  let paths: Paths
  private let fileSystem: CLIFilesystem
  private let privilegedShell: PrivilegedShell
  private let logger = Logger(subsystem: "com.gumpw.codans.ui", category: "cli-installer")

  init(
    paths: Paths = .default,
    fileSystem: CLIFilesystem = RealCLIFilesystem(),
    privilegedShell: PrivilegedShell = AppleScriptPrivilegedShell()
  ) {
    self.paths = paths
    self.fileSystem = fileSystem
    self.privilegedShell = privilegedShell
  }

  // MARK: - Probe

  /// Read-only state inspection. Never mutates, never throws; surfaces failures
  /// through `InstallStatus.failed` so the view renders them without special
  /// casing.
  ///
  /// - foreign destination → `.collision(owner:)`
  /// - our symlink → `.installed(pointsToBundle: true)`
  /// - a codans symlink into another build → `.installed(pointsToBundle: false)`
  /// - absent → `.notInstalled`
  func probe() -> InstallStatus {
    switch inspect(paths.tcSymlink) {
    case .foreign:
      return .collision(owner: paths.tcSymlink)
    case .ourSymlink:
      return .installed(at: paths.tcSymlink, pointsToBundle: true)
    case .staleOurs:
      return .installed(at: paths.tcSymlink, pointsToBundle: false)
    case .absent:
      return .notInstalled
    }
  }

  // MARK: - Install

  /// Symlinks `codans` under `/usr/local/bin/` to the bundled binary via a
  /// single privileged `do shell script` call. A foreign file at the
  /// destination aborts before the auth dialog opens, with **zero mutations**.
  ///
  /// Skips the auth dialog entirely when the symlink already resolves to our
  /// bundled binary (idempotent re-install). A codans symlink that points at
  /// another build — or at a binary a rebuild renamed away — is replaced in
  /// the same privileged call.
  func install() -> Result<InstallStatus, CLIInstallError> {
    guard let bundled = paths.bundledTcBinary else {
      return .failure(.bundleMissing(nil))
    }
    guard fileSystem.fileExists(atPath: bundled.path) else {
      return .failure(.bundleMissing(bundled))
    }

    let replacing: [URL]
    switch inspect(paths.tcSymlink) {
    case .foreign:
      return .failure(.destinationExistsNotOurs(paths.tcSymlink))
    case .ourSymlink:
      return .success(.installed(at: paths.tcSymlink, pointsToBundle: true))
    case .staleOurs:
      replacing = [paths.tcSymlink]
    case .absent:
      replacing = []
    }

    let legacyToCleanup = ourLegacyPaths()
    let script = Self.composeInstallScript(
      bundled: bundled,
      absentPaths: [paths.tcSymlink],
      replacing: replacing,
      legacyToCleanup: legacyToCleanup
    )
    do {
      try privilegedShell.run(
        script,
        prompt:
          "Codans needs administrator access to install the `\(paths.primaryCommandName)` command into /usr/local/bin."
      )
    } catch let error as PrivilegedShellError {
      return .failure(Self.mapPrivilegedError(error))
    } catch {
      return .failure(.scriptFailed(stderr: "\(error)"))
    }

    logger.info("codans installed at \(self.paths.tcSymlink.path, privacy: .public)")
    return .success(.installed(at: paths.tcSymlink, pointsToBundle: true))
  }

  // MARK: - Uninstall

  /// Removes the `codans` symlink iff the destination is ours or absent. A
  /// foreign file at the destination returns `.success(.collision(owner:))`
  /// without showing the auth dialog.
  ///
  /// Returns `.success(.notInstalled)` without showing the auth dialog when
  /// nothing belongs to us (idempotent re-uninstall).
  func uninstall() -> Result<InstallStatus, CLIInstallError> {
    switch inspect(paths.tcSymlink) {
    case .foreign:
      return .success(.collision(owner: paths.tcSymlink))
    case .absent:
      return .success(.notInstalled)
    case .ourSymlink, .staleOurs:
      break
    }

    let script = Self.composeUninstallScript(paths: [paths.tcSymlink])
    do {
      try privilegedShell.run(
        script,
        prompt:
          "Codans needs administrator access to remove `\(paths.primaryCommandName)` from /usr/local/bin."
      )
    } catch let error as PrivilegedShellError {
      return .failure(Self.mapPrivilegedError(error))
    } catch {
      return .failure(.scriptFailed(stderr: "\(error)"))
    }

    logger.info("codans uninstalled at \(self.paths.tcSymlink.path, privacy: .public)")
    return .success(.notInstalled)
  }

  // MARK: - Script composers

  /// Composes the `do shell script` body for an install. Includes `mkdir -p`
  /// for `/usr/local/bin` (idempotent; admin priv covers the create on bare
  /// macOS), an `rm` for each stale codans symlink being replaced, one
  /// `ln -s` per destination, and one `rm` per legacy `~/.local/bin/codans`
  /// that the unprivileged probe verified is our own symlink. Foreign
  /// entries are not touched.
  static func composeInstallScript(
    bundled: URL,
    absentPaths: [URL],
    replacing: [URL] = [],
    legacyToCleanup: [URL] = []
  ) -> String {
    var lines: [String] = ["set -e", "mkdir -p /usr/local/bin"]
    let target = shellEscape(bundled.path)
    for stale in replacing {
      // Same TOCTOU shape as the legacy cleanup below: re-check under
      // privilege that the entry is still a symlink into some app bundle's
      // `Resources/bin/` before removing it. If a foreign file took its
      // place, the guard skips the `rm` and the `ln -s` then fails loudly
      // instead of clobbering it.
      let path = shellEscape(stale.path)
      lines.append(
        "[ -L \(path) ] && case \"$(readlink \(path))\" in *\(bundledCLIPathMarker)*) rm \(path) ;; esac || true"
      )
    }
    for destination in absentPaths {
      lines.append("ln -s \(target) \(shellEscape(destination.path))")
    }
    for legacy in legacyToCleanup {
      // The TOCTOU window between the unprivileged probe and the privileged
      // execution lets a foreign symlink replace our legacy entry. The
      // [ -L ... ] guard alone would happily `rm` the foreign symlink.
      // Re-verify the target equals the bundled binary before deleting.
      let path = shellEscape(legacy.path)
      lines.append(
        "[ -L \(path) ] && [ \"$(readlink \(path))\" = \(target) ] && rm \(path) || true"
      )
    }
    return lines.joined(separator: "\n")
  }

  /// Composes the `do shell script` body for an uninstall — `rm` lines for
  /// each path the unprivileged probe verified as our symlink.
  static func composeUninstallScript(paths: [URL]) -> String {
    var lines: [String] = ["set -e"]
    for destination in paths {
      lines.append("rm \(shellEscape(destination.path))")
    }
    return lines.joined(separator: "\n")
  }

  private static func mapPrivilegedError(_ error: PrivilegedShellError) -> CLIInstallError {
    switch error {
    case .userCancelled:
      return .userCancelled
    case .scriptFailed(let stderr):
      return .scriptFailed(stderr: stderr)
    }
  }

  // MARK: - Helpers

  private enum LinkState: Equatable {
    case absent
    case ourSymlink
    /// A symlink codans wrote — it points into some app bundle's
    /// `Resources/bin/` — that does not resolve to this build's binary:
    /// another build's copy, or a target a rebuild renamed away (a Debug
    /// bundle embeds `codans-dev` where older ones embedded `codans`).
    case staleOurs
    case foreign
  }

  /// Only a codans installer links into an app bundle's `Resources/bin/`, so
  /// a symlink whose target contains this is ours to replace even when the
  /// target is gone. Checked against the link's literal destination, which
  /// survives a dangling target.
  static let bundledCLIPathMarker = ".app/Contents/Resources/bin/"

  /// Returns the legacy `~/.local/bin/codans` path if it resolves to our
  /// bundled binary. Foreign or absent entries are excluded — only an entry we
  /// know we created in a prior version qualifies for cleanup.
  private func ourLegacyPaths() -> [URL] {
    [paths.legacyLocalBinTc].filter { inspect($0) == .ourSymlink }
  }

  /// Classifies the destination path without mutating the filesystem. A path is
  /// "ours" iff it is a symlink and its resolved target (as absolute canonical
  /// path) equals the bundled binary's canonical path; a symlink into any other
  /// app bundle's `Resources/bin/` is ours but stale.
  private func inspect(_ destination: URL) -> LinkState {
    let attrs = try? fileSystem.attributesOfItem(atPath: destination.path)
    let isSymlink = (attrs?[.type] as? FileAttributeType) == .typeSymbolicLink
    if !isSymlink {
      if fileSystem.fileExists(atPath: destination.path) {
        return .foreign
      }
      if attrs != nil {
        return .foreign
      }
      return .absent
    }
    guard let rawTarget = try? fileSystem.destinationOfSymbolicLink(atPath: destination.path)
    else { return .foreign }
    let resolvedTarget: URL
    if rawTarget.hasPrefix("/") {
      resolvedTarget = URL(fileURLWithPath: rawTarget)
    } else {
      resolvedTarget = destination.deletingLastPathComponent().appendingPathComponent(rawTarget)
    }
    // Use resolvingSymlinksInPath so the comparison survives Gatekeeper
    // app-translocation aliases like /private/var/folders/.../AppTranslocation
    // and the /private/var ⇄ /var private-tmp aliasing macOS injects between
    // process startup and Bundle.main resolution. standardizedFileURL only
    // collapses dot segments — it does not chase the underlying alias.
    let resolvedPath = resolvedTarget.resolvingSymlinksInPath().path
    guard let bundled = paths.bundledTcBinary else { return .foreign }
    let bundledPath = bundled.resolvingSymlinksInPath().path
    if resolvedPath == bundledPath { return .ourSymlink }
    return rawTarget.contains(Self.bundledCLIPathMarker) ? .staleOurs : .foreign
  }

}

// MARK: - LocalizedError

extension CLIInstallerClient.CLIInstallError: LocalizedError {
  var errorDescription: String? {
    switch self {
    case .bundleMissing(let url):
      if let url {
        return "`codans` binary not found at \(url.path). Please reinstall Codans."
      }
      return "`codans` binary not found in the app bundle. Please reinstall Codans."
    case .destinationExistsNotOurs(let url):
      return
        "Another file exists at \(url.path). Rename or remove it, then retry — Codans will not overwrite a tool it did not install."
    case .userCancelled:
      return "Install cancelled. Click Install to retry."
    case .scriptFailed(let stderr):
      return "Install failed: \(stderr)"
    }
  }
}

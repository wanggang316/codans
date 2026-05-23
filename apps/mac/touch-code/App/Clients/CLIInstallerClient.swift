import Foundation
import TouchCodeCore
import os.log

/// Idempotent installer for the touch-code CLI. Release builds symlink `tc`
/// and `tcode` from `/usr/local/bin/` to the bundled binary inside
/// `touch-code.app`; Debug builds use `tc-dev` and `tcode-dev` so local
/// development never takes over the production command. The
/// privileged write is a single `do shell script` invocation with admin
/// privileges that runs `mkdir -p` + `ln -s` + (M4) legacy cleanup in one
/// transaction. `probe()` is unprivileged and safe to call on view-appear;
/// `install()` / `uninstall()` show the system auth dialog exactly once
/// per call (or zero times when no work remains — both already-our or both
/// already-absent paths).
///
/// `tc` and `tcode` are an atomic install pair. A foreign file at either
/// destination short-circuits the operation with `.collision(owner:)` and
/// no privileged dialog is shown.
@MainActor
final class CLIInstallerClient {
  /// URLs that parameterise the installer. Tests override everything; production
  /// uses the defaults pointing at `/usr/local/bin`.
  struct Paths: Equatable {
    var tcSymlink: URL
    var tcodeSymlink: URL
    /// Legacy `~/.local/bin/{tc,tcode}` paths from prior versions. The
    /// privileged install script in M4 will `rm` these only when they resolve
    /// to our bundled binary.
    var legacyLocalBinTc: URL
    var legacyLocalBinTcode: URL
    /// Bundled `tc` binary to symlink to. Resolved via `CLIBundleLocator`.
    /// `nil` when no bundled binary can be located — install surfaces this
    /// as `.bundleMissing`.
    var bundledTcBinary: URL?

    static var `default`: Paths {
      let home = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
      let usrLocalBin = URL(fileURLWithPath: "/usr/local/bin", isDirectory: true)
      let legacyLocalBin = home.appendingPathComponent(".local/bin", isDirectory: true)
      #if DEBUG
        let tcName = "tc-dev"
        let tcodeName = "tcode-dev"
      #else
        let tcName = "tc"
        let tcodeName = "tcode"
      #endif
      return Paths(
        tcSymlink: usrLocalBin.appendingPathComponent(tcName, isDirectory: false),
        tcodeSymlink: usrLocalBin.appendingPathComponent(tcodeName, isDirectory: false),
        legacyLocalBinTc: legacyLocalBin.appendingPathComponent(tcName, isDirectory: false),
        legacyLocalBinTcode: legacyLocalBin.appendingPathComponent(tcodeName, isDirectory: false),
        bundledTcBinary: try? CLIBundleLocator.locateBinary()
      )
    }

    var primaryCommandName: String { tcSymlink.lastPathComponent }
  }

  /// Current state of the `tc` / `tcode` symlink pair under
  /// `/usr/local/bin/`. Never persisted; the pane re-`probe()`s on appear.
  enum InstallStatus: Equatable {
    case unknown
    case notInstalled
    /// Both symlinks present and resolve to our bundled binary.
    case installed(at: URL, pointsToBundle: Bool)
    /// A file exists at `tcSymlink` or `tcodeSymlink` that is not our
    /// symlink. We never overwrite it.
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
  private let logger = Logger(subsystem: "com.touch-code.ui", category: "cli-installer")

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
  /// `tc` and `tcode` are treated as an **atomic install pair**. The returned
  /// status collapses the two-dimensional truth table into:
  /// - any destination foreign → `.collision(owner:)` (the first foreign URL)
  /// - both destinations `.ourSymlink` → `.installed(...)`
  /// - every other mix (both absent / one ours + one absent) → `.notInstalled`
  ///   (running `install()` from there completes the pair idempotently).
  func probe() -> InstallStatus {
    let pair = inspectPair()
    if let collision = pair.firstForeign {
      return .collision(owner: collision)
    }
    if pair.bothOurs {
      return .installed(at: paths.tcSymlink, pointsToBundle: true)
    }
    return .notInstalled
  }

  // MARK: - Install

  /// Symlinks `tc` and `tcode` under `/usr/local/bin/` to the bundled binary
  /// via a single privileged `do shell script` call. Atomic on the install
  /// pair: a foreign file at either destination aborts before the auth dialog
  /// opens, with **zero mutations**.
  ///
  /// Skips the auth dialog entirely when both symlinks already resolve to our
  /// bundled binary (idempotent re-install).
  func install() -> Result<InstallStatus, CLIInstallError> {
    guard let bundled = paths.bundledTcBinary else {
      return .failure(.bundleMissing(nil))
    }
    guard fileSystem.fileExists(atPath: bundled.path) else {
      return .failure(.bundleMissing(bundled))
    }

    let pair = inspectPair()
    if let foreign = pair.firstForeign {
      return .failure(.destinationExistsNotOurs(foreign))
    }
    if pair.bothOurs {
      return .success(.installed(at: paths.tcSymlink, pointsToBundle: true))
    }

    let absentPaths = pair.all.compactMap { $0.1 == .absent ? $0.0 : nil }
    let legacyToCleanup = ourLegacyPaths()
    let script = Self.composeInstallScript(
      bundled: bundled,
      absentPaths: absentPaths,
      legacyToCleanup: legacyToCleanup
    )
    do {
      try privilegedShell.run(
        script,
        prompt:
          "TouchCode needs administrator access to install the `\(paths.primaryCommandName)` command into /usr/local/bin."
      )
    } catch let error as PrivilegedShellError {
      return .failure(Self.mapPrivilegedError(error))
    } catch {
      return .failure(.scriptFailed(stderr: "\(error)"))
    }

    logger.info("tc installed at \(self.paths.tcSymlink.path, privacy: .public)")
    return .success(.installed(at: paths.tcSymlink, pointsToBundle: true))
  }

  // MARK: - Uninstall

  /// Removes the `tc` and `tcode` symlinks iff both destinations are ours or
  /// absent. A foreign file at either destination returns
  /// `.success(.collision(owner:))` without showing the auth dialog.
  ///
  /// Returns `.success(.notInstalled)` without showing the auth dialog when
  /// nothing belongs to us (idempotent re-uninstall).
  func uninstall() -> Result<InstallStatus, CLIInstallError> {
    let pair = inspectPair()
    if let foreign = pair.firstForeign {
      return .success(.collision(owner: foreign))
    }
    let oursToRemove = pair.all.compactMap { $0.1 == .ourSymlink ? $0.0 : nil }
    if oursToRemove.isEmpty {
      return .success(.notInstalled)
    }

    let script = Self.composeUninstallScript(paths: oursToRemove)
    do {
      try privilegedShell.run(
        script,
        prompt:
          "TouchCode needs administrator access to remove `\(paths.primaryCommandName)` from /usr/local/bin."
      )
    } catch let error as PrivilegedShellError {
      return .failure(Self.mapPrivilegedError(error))
    } catch {
      return .failure(.scriptFailed(stderr: "\(error)"))
    }

    logger.info("tc uninstalled at \(self.paths.tcSymlink.path, privacy: .public)")
    return .success(.notInstalled)
  }

  // MARK: - Script composers

  /// Composes the `do shell script` body for an install. Includes `mkdir -p`
  /// for `/usr/local/bin` (idempotent; admin priv covers the create on bare
  /// macOS), one `ln -s` per absent destination, and one `rm` per legacy
  /// `~/.local/bin/{tc,tcode}` that the unprivileged probe verified is our
  /// own symlink. Foreign legacy entries are not touched.
  static func composeInstallScript(
    bundled: URL,
    absentPaths: [URL],
    legacyToCleanup: [URL] = []
  ) -> String {
    var lines: [String] = ["set -e", "mkdir -p /usr/local/bin"]
    let target = shellEscape(bundled.path)
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
    case foreign
  }

  /// Classification of the two-destination install pair. Order is always
  /// [tcSymlink, tcodeSymlink] so callers can produce deterministic error
  /// messages.
  private struct PairInspection {
    let all: [(URL, LinkState)]

    /// First foreign URL, if any — traversal order matches `all`.
    var firstForeign: URL? {
      all.first(where: { $0.1 == .foreign })?.0
    }

    /// True iff both destinations are our symlinks.
    var bothOurs: Bool {
      all.allSatisfy { $0.1 == .ourSymlink }
    }
  }

  private func inspectPair() -> PairInspection {
    PairInspection(all: [
      (paths.tcSymlink, inspect(paths.tcSymlink)),
      (paths.tcodeSymlink, inspect(paths.tcodeSymlink)),
    ])
  }

  /// Returns the legacy `~/.local/bin/{tc,tcode}` paths that resolve to our
  /// bundled binary. Foreign or absent entries are excluded — only entries we
  /// know we created in a prior version qualify for cleanup.
  private func ourLegacyPaths() -> [URL] {
    [paths.legacyLocalBinTc, paths.legacyLocalBinTcode].filter { inspect($0) == .ourSymlink }
  }

  /// Classifies the destination path without mutating the filesystem. A path is
  /// "ours" iff it is a symlink and its resolved target (as absolute canonical
  /// path) equals the bundled binary's canonical path.
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
    return resolvedPath == bundledPath ? .ourSymlink : .foreign
  }

}

// MARK: - LocalizedError

extension CLIInstallerClient.CLIInstallError: LocalizedError {
  var errorDescription: String? {
    switch self {
    case .bundleMissing(let url):
      if let url {
        return "`tc` binary not found at \(url.path). Please reinstall TouchCode."
      }
      return "`tc` binary not found in the app bundle. Please reinstall TouchCode."
    case .destinationExistsNotOurs(let url):
      return
        "Another file exists at \(url.path). Rename or remove it, then retry — TouchCode will not overwrite a tool it did not install."
    case .userCancelled:
      return "Install cancelled. Click Install to retry."
    case .scriptFailed(let stderr):
      return "Install failed: \(stderr)"
    }
  }
}

import Foundation
import CodansCore

/// App-tier descriptor for a single editor entry. A descriptor is produced by resolving a
/// registry row against the live `AppLauncher`: `appURL` carries the Launch Services lookup
/// result (nil for `.shellEditor` and for not-installed entries).
///
/// `describe()` returns only installed entries; absence of a descriptor IS the "not installed"
/// signal — there is no `InstallationStatus` enum in C8a.
public nonisolated struct EditorDescriptor: Equatable, Hashable, Sendable, Identifiable, Codable {
  /// How the service launches a directory in this editor. Each branch corresponds to one
  /// mechanism in `EditorService.open`.
  public enum LaunchMode: String, Equatable, Hashable, Sendable, Codable {
    /// `NSWorkspace.open(urls:withApplicationAt:configuration:)` with a single directory URL.
    case directory
    /// `NSWorkspace.openApplication(at:configuration:)` with
    /// `configuration.arguments = [dir]` and `createsNewApplicationInstance = true`.
    /// JetBrains-family only — other modes cause the IDE to focus its last-opened window and
    /// ignore the argument.
    case applicationWithArguments
    /// Spawn a Pane at the target directory and send `$EDITOR\n` as initial input. The
    /// user's login shell resolves `$EDITOR` with its own environment. No bundle ID, no LS.
    case shellEditor
  }

  public let id: EditorID
  public let displayName: String
  /// Launch Services bundle identifier. Empty string for `.shellEditor` (no bundle).
  public let bundleIdentifier: String
  public let launchMode: LaunchMode
  /// Resolved `.app` URL from Launch Services, or nil for `.shellEditor` / not-installed.
  /// Registry rows always start with `appURL = nil`; the service populates this at `describe`
  /// time against the live `AppLauncher`.
  public let appURL: URL?
  /// Fallback bundle identifiers probed when the primary misses. Covers R1 (ToDesktop-style
  /// bundle ID drift, e.g. future Cursor re-publishes). Empty by default.
  public let alternateBundleIdentifiers: [String]

  public init(
    id: EditorID,
    displayName: String,
    bundleIdentifier: String,
    launchMode: LaunchMode,
    appURL: URL?,
    alternateBundleIdentifiers: [String] = []
  ) {
    self.id = id
    self.displayName = displayName
    self.bundleIdentifier = bundleIdentifier
    self.launchMode = launchMode
    self.appURL = appURL
    self.alternateBundleIdentifiers = alternateBundleIdentifiers
  }
}

/// Resolved editor returned from `EditorService.open` on success. `argv` is gone in C8a —
/// NSWorkspace launches have no argv to expose and no consumer needed it.
public nonisolated struct EditorChoice: Equatable, Hashable, Sendable, Codable {
  public let id: EditorID
  public let displayName: String
  /// Optional binary path. Absent for NSWorkspace launches (Launch Services owns the bundle);
  /// populated only for `.shellEditor` where the Pane's shell resolves `$EDITOR`.
  public let binaryPath: String?

  public init(id: EditorID, displayName: String, binaryPath: String? = nil) {
    self.id = id
    self.displayName = displayName
    self.binaryPath = binaryPath
  }
}

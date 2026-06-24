import AppKit
import Foundation
import CodansCore

/// Production `EditorService` backed by Launch Services via the `AppLauncher` seam.
///
/// State: the `describe()` result is memoised for the service's lifetime. Settings panes
/// (and the IPC `editor.describe` handler) call `clearCache()` on appear so newly-installed
/// editors surface without an app restart.
///
/// Threading: an `actor` gives us a cheap mutex around the cache without hand-rolling a
/// lock. The `Sendable` closures for reading settings let the live factory close over
/// `@MainActor`-isolated stores without the service itself needing to hop to the main actor
/// on every resolve.
final actor LiveEditorService: EditorService {
  private let launcher: any AppLauncher
  private let globalDefault: @Sendable () async -> EditorID?
  private var cachedDescriptors: [EditorDescriptor]?

  init(
    launcher: any AppLauncher = LiveAppLauncher(),
    globalDefault: @escaping @Sendable () async -> EditorID? = { nil }
  ) {
    self.launcher = launcher
    self.globalDefault = globalDefault
  }

  // MARK: - describe

  func describe() async -> [EditorDescriptor] {
    if let cached = cachedDescriptors { return cached }
    var resolved: [EditorDescriptor] = []
    for template in EditorRegistry.registry {
      switch template.launchMode {
      case .shellEditor:
        // Always-installed pseudo-editor (no bundle to probe). Surfacing the row lets the
        // Settings + Worktree-header pickers list it; actually opening $EDITOR throws here
        // and must route through `hierarchyClient.openPane(... initialCommand: "$EDITOR")`
        // (see the `.shellEditor` branch of `open(directory:preferred:)` below).
        resolved.append(
          EditorDescriptor(
            id: template.id,
            displayName: template.displayName,
            bundleIdentifier: template.bundleIdentifier,
            launchMode: template.launchMode,
            appURL: nil,
            alternateBundleIdentifiers: template.alternateBundleIdentifiers
          )
        )
      case .directory, .applicationWithArguments:
        if let appURL = await resolveAppURL(for: template) {
          resolved.append(
            EditorDescriptor(
              id: template.id,
              displayName: template.displayName,
              bundleIdentifier: template.bundleIdentifier,
              launchMode: template.launchMode,
              appURL: appURL,
              alternateBundleIdentifiers: template.alternateBundleIdentifiers
            )
          )
        }
      }
    }
    cachedDescriptors = resolved
    return resolved
  }

  /// Invalidates the `describe()` cache. Call on Settings-pane appear and on IPC
  /// `editor.describe` so a newly-installed editor becomes visible without restart.
  func clearCache() {
    cachedDescriptors = nil
  }

  // MARK: - resolve

  func resolve(preferred: EditorID?) async throws -> EditorDescriptor {
    let installed = await describe()

    // Tier 1 — explicit preferred (strict).
    if let preferred {
      guard let match = installed.first(where: { $0.id == preferred }) else {
        let bundleID = EditorRegistry.registry.first(where: { $0.id == preferred })?.bundleIdentifier ?? ""
        throw EditorError.notInstalled(id: preferred, bundleID: bundleID)
      }
      return match
    }

    // Tier 2 — stored global default (lenient: silently skip if uninstalled).
    if let defaultID = await globalDefault(),
      let match = installed.first(where: { $0.id == defaultID })
    {
      return match
    }

    // Tier 3 — priority walk. Finder is always installed, so this always terminates.
    for id in EditorRegistry.defaultPriority {
      if let match = installed.first(where: { $0.id == id }) {
        return match
      }
    }

    // Defensive: Launch Services claims Finder is missing. Surface a launch error rather
    // than force-unwrapping — the caller can render a toast and the user can at least
    // retry.
    throw EditorError.launchFailed(reason: "No installed editor found in the priority chain.")
  }

  // MARK: - open

  @discardableResult
  func open(directory: URL, preferred: EditorID?) async throws -> EditorChoice {
    try ensureDirectoryExists(directory)
    let descriptor = try await resolve(preferred: preferred)

    switch descriptor.launchMode {
    case .directory:
      guard let appURL = descriptor.appURL else {
        throw EditorError.launchFailed(reason: "Resolved \(descriptor.id) has no app URL.")
      }
      let config = NSWorkspace.OpenConfiguration()
      try await launcher.open(urls: [directory], withApplicationAt: appURL, configuration: config)

    case .applicationWithArguments:
      guard let appURL = descriptor.appURL else {
        throw EditorError.launchFailed(reason: "Resolved \(descriptor.id) has no app URL.")
      }
      let config = NSWorkspace.OpenConfiguration()
      config.arguments = [directory.path]
      config.createsNewApplicationInstance = true
      // JetBrains IDEs expect `arguments` to arrive through
      // `NSWorkspace.openApplication(at:configuration:)`. Calling `open(urls:…)` with an
      // empty URL list is undefined and does not forward `configuration.arguments` to the
      // launched app — the IDE would open at its last-active project instead of the
      // directory the user asked for.
      try await launcher.openApplication(at: appURL, configuration: config)

    case .shellEditor:
      // The Pane primitive exists (`TerminalEngine.ensureSurface` forwards
      // `pane.initialCommand`), but this service can't address a Pane: `.shellEditor` needs a
      // `(projectID, worktreeID, tabID)` tuple to hand `HierarchyManager.openPane`, and the
      // `(directory: URL, preferred: EditorID?)` signature intentionally excludes domain
      // types. So fail with a descriptive error rather than silently no-op'ing — the registry
      // entry keeps its shape in `describe()`, and callers that want `.shellEditor` end to end
      // route through the Pane/Tab-aware path (e.g. the worktree header "Open in ▾").
      throw EditorError.launchFailed(
        reason:
          "$EDITOR requires a Tab context that EditorService does not have. "
          + "Open a Pane via the Worktree header or `hierarchy.openPane` with initialCommand=\"$EDITOR\"."
      )
    }

    return EditorChoice(id: descriptor.id, displayName: descriptor.displayName, binaryPath: nil)
  }

  // MARK: - Helpers

  /// Probes the launcher for the template's primary bundle ID, falling through to
  /// `alternateBundleIdentifiers`. Returns nil if no bundle is registered for any of them.
  private func resolveAppURL(for template: EditorDescriptor) async -> URL? {
    if let url = await launcher.urlForApplication(bundleIdentifier: template.bundleIdentifier) {
      return url
    }
    for alternate in template.alternateBundleIdentifiers {
      if let url = await launcher.urlForApplication(bundleIdentifier: alternate) {
        return url
      }
    }
    return nil
  }

  private func ensureDirectoryExists(_ url: URL) throws {
    var isDir: ObjCBool = false
    let fm = FileManager.default
    guard fm.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue else {
      throw EditorError.notADirectory(path: url.path)
    }
  }
}

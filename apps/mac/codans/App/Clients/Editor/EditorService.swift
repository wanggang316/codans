import Foundation
import CodansCore

/// External-editor dispatch surface. Consumed by the TCA `EditorClient` bridge and, through
/// it, by the Worktree-header dropdown and the `editor.*` IPC handlers. The service is a
/// pure path-opener: callers resolve their own context (Worktree / Project / CLI arg) to a
/// directory URL and hand it in. No domain type crosses the boundary.
///
/// All methods are `async` to leave room for future I/O; today the resolution path is
/// CPU-bound (Launch Services calls are synchronous) but the signature stays async for
/// consistency with the TCA client surface.
public nonisolated protocol EditorService: Sendable {
  /// Probes every registry entry against the live `AppLauncher` and returns the installed
  /// subset. `.shellEditor` is always considered installed (no bundle to probe). The live
  /// implementation caches the result for the process lifetime; call `clearCache()` to
  /// invalidate when the user may have installed a new editor.
  func describe() async -> [EditorDescriptor]

  /// Resolves the effective editor for a `preferred` hint, without opening anything.
  /// Cascades:
  ///   1. `preferred` set + installed → return it. Set + uninstalled → throw `.notInstalled`.
  ///   2. `settings.general.defaultEditorID` set + installed → return it. Missing → skip.
  ///   3. `EditorRegistry.defaultPriority` walk → first installed (always terminates at Finder).
  ///
  /// Strict on step 1 (user asked for a specific editor — surface the error); lenient on
  /// step 2 (stored default is advisory).
  func resolve(preferred: EditorID?) async throws -> EditorDescriptor

  /// Opens `directory` in the resolved editor. Branches on `descriptor.launchMode`:
  /// `.directory` and `.applicationWithArguments` go through `AppLauncher.open`; the
  /// `.shellEditor` path delegates to the Pane primitive (Phase 4d).
  ///
  /// Throws:
  ///   - `.notADirectory` if `directory` does not exist or is not a directory.
  ///   - `.notInstalled` if `preferred` is set but not installed.
  ///   - `.launchFailed` if `NSWorkspace.open` reports an error (or for the `.shellEditor`
  ///     branch until Phase 4d wires the Pane primitive).
  @discardableResult
  func open(directory: URL, preferred: EditorID?) async throws -> EditorChoice
}

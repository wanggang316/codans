import CodansCore
import Foundation

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
  /// `.shellEditor` path cannot complete here (it needs a Pane context the service signature
  /// excludes) and always throws `.launchFailed`.
  ///
  /// Throws:
  ///   - `.notADirectory` if `directory` does not exist or is not a directory.
  ///   - `.notInstalled` if `preferred` is set but not installed.
  ///   - `.launchFailed` if `NSWorkspace.open` reports an error, or for the `.shellEditor`
  ///     branch.
  @discardableResult
  func open(directory: URL, preferred: EditorID?) async throws -> EditorChoice

  /// Opens `remotePath` on `host` through the resolved editor's SSH remoting
  /// CLI (see `RemoteEditorOpen`). Resolution is lenient on `preferred`: a
  /// preference that cannot express this host (no SSH story, or a VS Code
  /// family editor on a non-default port) falls through to the global default
  /// and then the priority walk, both filtered the same way — so the call
  /// lands on a host-capable editor whenever one is installed.
  ///
  /// Throws `.launchFailed` when no installed editor can open this host, or
  /// when the editor's CLI exits non-zero.
  @discardableResult
  func openRemote(host: RemoteHost, remotePath: String, preferred: EditorID?) async throws
    -> EditorChoice
}

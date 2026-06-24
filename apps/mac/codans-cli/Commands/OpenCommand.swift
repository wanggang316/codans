import ArgumentParser
import Foundation
import CodansCore
import CodansIPC
import CodansKit

/// `codans open [--in <editor>] [<path>]` — launch an external editor (or terminal / git client /
/// Finder / `$EDITOR`) against a directory by calling the app-side `editor.open` RPC.
///
/// `path` is a single positional argument (defaults to `$PWD`). The per-Project override
/// lookup happens server-side in `EditorHandlers.open` — the CLI just sends the canonical
/// path + optional explicit `--in` editor.
///
/// Editor precedence (handled server-side by EditorService):
///  1. `--in` explicit flag on this command (strict: throws if uninstalled).
///  2. `Settings.projects[pid].defaultEditor` if the path is inside a registered Project (lenient).
///  3. `Settings.defaultEditorID` (lenient).
///  4. Priority walk through the built-in registry (Cursor → Zed → VSCode → …).
///  5. Finder fallback (always available).
struct OpenCommand: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "open",
    abstract: "Open a directory in an external editor (or terminal / git client / Finder)."
  )
  @OptionGroup var globals: GlobalOptions
  @Option(
    name: .long,
    help: "Editor id (e.g. cursor, zed, vscode, xcode, finder, ghostty). Omit to use per-Project / Settings defaults."
  )
  var `in`: String?
  @Argument(help: "Directory to open. Defaults to $PWD.")
  var path: String?

  func run() async throws {
    let client = CLISession.connect(globals: globals)
    defer { Task { await client.shutdown() } }
    do {
      let request = Self.buildRequest(path: self.path, editor: self.in)
      let response: EditorOpenResponse = try await client.call(.editorOpen, params: request)
      try Renderer.emitObject(
        ["editor": response.choice.displayName, "path": request.path],
        mode: globals.renderMode
      ) { obj in
        "opened \(obj["path"] ?? "?") in \(obj["editor"] ?? "?")"
      }
    } catch {
      CLIError.from(error).exitProcess()
    }
  }

  /// Build the canonical `EditorOpenRequest`. Empty / missing `<path>` falls back to `$PWD`;
  /// relative paths are resolved against `$PWD`. The server canonicalizes via
  /// `HierarchyManager.canonicalPath` so we don't need to resolve symlinks client-side.
  static func buildRequest(path: String?, editor: String?) -> EditorOpenRequest {
    let pwd = FileManager.default.currentDirectoryPath
    let raw = (path?.isEmpty == false) ? path! : pwd
    let resolved: String
    if raw.hasPrefix("/") {
      resolved = raw
    } else {
      resolved = URL(fileURLWithPath: pwd).appendingPathComponent(raw).path
    }
    return EditorOpenRequest(path: resolved, preferred: editor)
  }
}

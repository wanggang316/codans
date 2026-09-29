import AppKit
import CodansCore
import ComposableArchitecture
import Foundation
import UniformTypeIdentifiers
import os.log

/// Opens a link ⌘-clicked in terminal output. Scheme URLs go to
/// LaunchServices; files open in the project's editor at the parsed line,
/// over SSH for Server projects. Plain directories open in Finder, rendered
/// documents (images, PDF, HTML) in their default app, and anything that
/// could launch or execute (bundles, or a file the editor refuses) is only
/// revealed in Finder.
nonisolated struct TerminalLinkClient: Sendable {
  var open: @MainActor @Sendable (_ paneID: PaneID, _ raw: String, _ workingDirectory: String?) async throws -> Void
}

nonisolated enum TerminalLinkError: LocalizedError, Equatable {
  case unresolvable(String)
  case fileNotFound(String)

  var errorDescription: String? {
    switch self {
    case .unresolvable(let raw): return "Cannot resolve link: \(raw)"
    case .fileNotFound(let path): return "File not found: \(path)"
    }
  }
}

extension TerminalLinkClient: DependencyKey {
  private static let logger = Logger(subsystem: "com.gumpw.codans.app", category: "terminal-link")

  static let liveValue = Self { paneID, raw, workingDirectory in
    @Dependency(HierarchyClient.self) var hierarchyClient
    let catalog = hierarchyClient.snapshot()
    let address = hierarchyClient.addressOf(paneID)
    let project = address.flatMap { address in catalog.projects.first { $0.id == address.projectID } }
    let worktree = address.flatMap { address in project?.worktrees.first { $0.id == address.worktreeID } }
    let isRemote = project?.remoteHost != nil
    // libghostty drops OSC 7 reports naming a non-local host, so a Server
    // project's pwd is absent or stale; fall back to the catalog's remote path.
    let base =
      (isRemote ? nil : workingDirectory) ?? catalog.pane(paneID)?.workingDirectory ?? worktree?.path
    let fileManager = FileManager.default
    guard
      let link = TerminalLink.parse(
        raw, baseDirectory: base,
        homeDirectory: isRemote ? nil : NSHomeDirectory(),
        fileExists: isRemote ? nil : { fileManager.fileExists(atPath: $0) }
      )
    else { throw TerminalLinkError.unresolvable(raw) }

    switch link {
    case .external(let url):
      NSWorkspace.shared.open(url)

    case .file(let location):
      let file = URL(fileURLWithPath: location.path)
      let context = await ProjectEditorContext.resolve(project?.id)
      if let host = context.host {
        try await context.service.openFile(
          file, line: location.line, preferred: context.preferred, host: host,
          cwd: URL(fileURLWithPath: NSHomeDirectory()))
        return
      }
      var isDirectory: ObjCBool = false
      guard fileManager.fileExists(atPath: file.path, isDirectory: &isDirectory) else {
        throw TerminalLinkError.fileNotFound(location.path)
      }
      if isDirectory.boolValue {
        if NSWorkspace.shared.isFilePackage(atPath: file.path) {
          NSWorkspace.shared.activateFileViewerSelecting([file])
        } else {
          NSWorkspace.shared.open(file)
        }
        return
      }
      if location.line == nil, opensInDefaultApp(file) {
        NSWorkspace.shared.open(file)
        return
      }
      do {
        try await context.service.openFile(
          file, line: location.line, preferred: context.preferred, host: nil,
          cwd: file.deletingLastPathComponent())
      } catch {
        // The preferred editor has no file-level launch path (e.g. $EDITOR).
        logger.info("terminal link: editor open failed, revealing instead: \(error.localizedDescription)")
        NSWorkspace.shared.activateFileViewerSelecting([file])
      }
    }
  }

  static let testValue = Self(open: unimplemented("TerminalLinkClient.open"))

  /// Rendered documents belong in their viewer. Everything else goes to the
  /// code editor: extension-based types are unreliable for source (`.ts` is
  /// registered as MPEG-2 video), and the editor never executes anything.
  nonisolated static func opensInDefaultApp(_ file: URL) -> Bool {
    guard let type = UTType(filenameExtension: file.pathExtension) else { return false }
    return [UTType.image, .pdf, .html].contains { type.conforms(to: $0) }
  }
}

extension DependencyValues {
  var terminalLinkClient: TerminalLinkClient {
    get { self[TerminalLinkClient.self] }
    set { self[TerminalLinkClient.self] = newValue }
  }
}

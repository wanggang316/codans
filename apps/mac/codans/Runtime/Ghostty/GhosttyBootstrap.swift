import CodansCore
import Foundation
import GhosttyKit

/// One-time process-global Ghostty initialization. Must run before any other
/// ghostty C API. Sets GHOSTTY_RESOURCES_DIR and TERMINFO_DIRS so libghostty
/// can locate its shaders, default config, and terminfo entries.
///
/// Resource lookup order:
/// 1. Bundle.main.resourceURL (expected for shipped .app bundles)
/// 2. `CODANS_GHOSTTY_RESOURCES` env override (for dev/debug runs)
/// 3. Hardcoded .build/ghostty/share/{ghostty,terminfo} next to Project.swift
enum GhosttyBootstrap {
  private static let argv: [UnsafeMutablePointer<CChar>?] = {
    [
      strdup(CommandLine.arguments.first ?? "codans"),
      nil,
    ]
  }()

  static let initialize: Void = {
    let dirs = resolveResourceDirs()
    setenv(CodansEnvironment.Key.ghosttyResourcesDirectory.rawValue, dirs.ghostty.path, 1)
    setenv(CodansEnvironment.Key.terminfoDirectories.rawValue, dirs.terminfo.path, 1)

    argv.withUnsafeBufferPointer { buffer in
      let argc = UInt(max(0, buffer.count - 1))
      let argv = UnsafeMutablePointer(mutating: buffer.baseAddress)
      let rc = ghostty_init(argc, argv)
      precondition(rc == GHOSTTY_SUCCESS, "ghostty_init failed with code \(rc)")
    }
  }()

  private static func resolveResourceDirs() -> (ghostty: URL, terminfo: URL) {
    let fm = FileManager.default
    if let bundleURL = Bundle.main.resourceURL,
      let pair = candidatePair(at: bundleURL, fileManager: fm)
    {
      return pair
    }
    if let override = ProcessInfo.processInfo.environment[CodansEnvironment.Key.ghosttyResources.rawValue],
      let pair = candidatePair(at: URL(fileURLWithPath: override), fileManager: fm)
    {
      return pair
    }

    let srcroot = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
    let buildShare = srcroot.appendingPathComponent(".build/ghostty/share", isDirectory: true)
    return (
      buildShare.appendingPathComponent("ghostty", isDirectory: true),
      buildShare.appendingPathComponent("terminfo", isDirectory: true)
    )
  }

  private static func candidatePair(
    at root: URL,
    fileManager fm: FileManager
  ) -> (ghostty: URL, terminfo: URL)? {
    let ghostty = root.appendingPathComponent("ghostty", isDirectory: true)
    let terminfo = root.appendingPathComponent("terminfo", isDirectory: true)
    var isDir = ObjCBool(false)
    guard fm.fileExists(atPath: ghostty.path, isDirectory: &isDir), isDir.boolValue,
      fm.fileExists(atPath: terminfo.path, isDirectory: &isDir), isDir.boolValue
    else {
      return nil
    }
    return (ghostty, terminfo)
  }
}

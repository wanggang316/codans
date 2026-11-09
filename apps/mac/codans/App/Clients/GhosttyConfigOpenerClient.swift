import AppKit
import ComposableArchitecture
import Foundation
import UniformTypeIdentifiers
import os.log

/// Opens the user's Ghostty config file. The one implementation behind the
/// Ghostty `open_config` action, the "Open Ghostty Config" command palette
/// item, and the Settings → Terminal "Open in text editor" button.
///
/// `testValue` is unimplemented so that no reducer test can open a real file:
/// the test host is the Codans app, and a live `NSWorkspace.open` call there
/// really launches an editor.
nonisolated struct GhosttyConfigOpenerClient: Sendable {
  /// The config file that Settings reads and writes
  /// (`GhosttyConfigFile.resolvedConfigURL()`, which honors `XDG_CONFIG_HOME`).
  var configURL: @MainActor @Sendable () -> URL
  /// Opens `url` in the default plain-text editor, or opens its directory
  /// when the file does not exist yet.
  var open: @MainActor @Sendable (_ url: URL) -> Void
}

extension GhosttyConfigOpenerClient {
  /// What `open` hands to LaunchServices for a config URL.
  enum OpenTarget: Equatable {
    case file(URL)
    case directory(URL)
  }

  /// A config file that does not exist yet (nothing has been saved) cannot
  /// open in an editor, so open its directory instead.
  static func openTarget(for url: URL, fileExists: Bool) -> OpenTarget {
    fileExists ? .file(url) : .directory(url.deletingLastPathComponent())
  }

  static func live(
    environment: [String: String] = ProcessInfo.processInfo.environment,
    homeDirectoryURL: URL = FileManager.default.homeDirectoryForCurrentUser
  ) -> Self {
    Self(
      configURL: {
        GhosttyConfigFile(
          homeDirectoryURL: homeDirectoryURL,
          environment: environment,
          catalogProvider: { .empty },
          fontFamilyProvider: { .empty }
        ).resolvedConfigURL()
      },
      open: { url in
        let fileExists = FileManager.default.fileExists(atPath: url.path)
        switch openTarget(for: url, fileExists: fileExists) {
        case .file(let file):
          openFile(file)
        case .directory(let directory):
          openDirectory(directory)
        }
      }
    )
  }

  private static let logger = Logger(
    subsystem: "com.gumpw.codans.ui", category: "ghostty-config-opener"
  )

  /// The file has no extension, so route through the plain-text handler:
  /// `open(_:)` can fail to find an association for an extensionless file.
  @MainActor
  private static func openFile(_ url: URL) {
    guard let editor = NSWorkspace.shared.urlForApplication(toOpen: UTType.plainText) else {
      if !NSWorkspace.shared.open(url) {
        logger.error("Could not open Ghostty config \(url.path, privacy: .public)")
      }
      return
    }
    NSWorkspace.shared.open(
      [url], withApplicationAt: editor, configuration: NSWorkspace.OpenConfiguration()
    ) { _, error in
      if let error {
        logger.error(
          "Could not open Ghostty config \(url.path, privacy: .public): \(error.localizedDescription, privacy: .public)"
        )
      }
    }
  }

  /// Create the directory when it is missing too, so the user always lands
  /// where the config file goes.
  @MainActor
  private static func openDirectory(_ url: URL) {
    do {
      try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    } catch {
      logger.error(
        "Could not create Ghostty config directory \(url.path, privacy: .public): \(error.localizedDescription, privacy: .public)"
      )
      return
    }
    if !NSWorkspace.shared.open(url) {
      logger.error("Could not open Ghostty config directory \(url.path, privacy: .public)")
    }
  }
}

// MARK: - DependencyKey

extension GhosttyConfigOpenerClient: DependencyKey {
  static let liveValue = GhosttyConfigOpenerClient.live()

  static let testValue = GhosttyConfigOpenerClient(
    configURL: unimplemented(
      "GhosttyConfigOpenerClient.configURL",
      placeholder: URL(fileURLWithPath: "/tmp/codans-tests/ghostty/config")
    ),
    open: unimplemented("GhosttyConfigOpenerClient.open")
  )
}

extension DependencyValues {
  var ghosttyConfigOpener: GhosttyConfigOpenerClient {
    get { self[GhosttyConfigOpenerClient.self] }
    set { self[GhosttyConfigOpenerClient.self] = newValue }
  }
}

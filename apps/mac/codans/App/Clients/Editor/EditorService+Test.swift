import AppKit
import CodansCore
import Foundation

/// In-memory `EditorService` for tests. Holds canned `describe()` / `resolve()` / `open()`
/// outputs and records every open call for assertion. Designed to drop into TCA `TestStore`s
/// via `$0.editorClient = .mock(TestEditorService(...))` — see `EditorClient.testValue`.
///
/// An `actor` (rather than a struct) is used for the same reason as the live service:
/// callers are free to mutate stub behaviour between invocations from any context.
final actor TestEditorService: EditorService {
  /// Descriptors returned by `describe()`. Default: an empty list (no editors installed).
  private var describeStub: [EditorDescriptor]
  /// Closure used by `resolve()`. When nil, returns `TestEditorService.defaultDescriptor`.
  private var resolveStub: (@Sendable (EditorID?) throws -> EditorDescriptor)?
  /// Closure used by `open()`. When nil, returns `TestEditorService.defaultChoice`.
  private var openStub: (@Sendable (URL, EditorID?) throws -> EditorChoice)?

  /// Every `open` invocation in call order.
  private(set) var openCalls: [OpenCall] = []
  /// Every `openRemote` invocation in call order.
  private(set) var openRemoteCalls: [OpenRemoteCall] = []

  struct OpenCall: Equatable, Sendable {
    let directory: URL
    let preferred: EditorID?
  }

  struct OpenRemoteCall: Equatable, Sendable {
    let host: RemoteHost
    let remotePath: String
    let preferred: EditorID?
  }

  init(
    describe: [EditorDescriptor] = [],
    resolve: (@Sendable (EditorID?) throws -> EditorDescriptor)? = nil,
    open: (@Sendable (URL, EditorID?) throws -> EditorChoice)? = nil
  ) {
    self.describeStub = describe
    self.resolveStub = resolve
    self.openStub = open
  }

  // MARK: - Stub mutators

  func setDescribeStub(_ descriptors: [EditorDescriptor]) { describeStub = descriptors }
  func setResolveStub(_ stub: (@Sendable (EditorID?) throws -> EditorDescriptor)?) {
    resolveStub = stub
  }
  func setOpenStub(_ stub: (@Sendable (URL, EditorID?) throws -> EditorChoice)?) { openStub = stub }

  // MARK: - EditorService

  func describe() -> [EditorDescriptor] { describeStub }

  func resolve(preferred: EditorID?) throws -> EditorDescriptor {
    if let resolveStub { return try resolveStub(preferred) }
    if let preferred, let match = describeStub.first(where: { $0.id == preferred }) {
      return match
    }
    return describeStub.first(where: { $0.id == EditorRegistry.finderID })
      ?? Self.defaultDescriptor
  }

  @discardableResult
  func openRemote(
    host: RemoteHost, remotePath: String, preferred: EditorID?
  ) throws -> EditorChoice {
    openRemoteCalls.append(
      OpenRemoteCall(host: host, remotePath: remotePath, preferred: preferred)
    )
    return Self.defaultChoice
  }

  @discardableResult
  func open(directory: URL, preferred: EditorID?) throws -> EditorChoice {
    openCalls.append(OpenCall(directory: directory, preferred: preferred))
    if let openStub { return try openStub(directory, preferred) }
    return Self.defaultChoice
  }

  // MARK: - Fixtures

  static let defaultDescriptor = EditorDescriptor(
    id: EditorRegistry.finderID,
    displayName: "Finder",
    bundleIdentifier: "com.apple.finder",
    launchMode: .directory,
    appURL: URL(fileURLWithPath: "/System/Library/CoreServices/Finder.app"),
    alternateBundleIdentifiers: []
  )

  static let defaultChoice = EditorChoice(
    id: EditorRegistry.finderID,
    displayName: "Finder",
    binaryPath: nil
  )
}

/// Recording double for `AppLauncher`. Used by `LiveEditorService` unit tests to verify the
/// `(mode, appURL, urls, configuration.arguments, configuration.createsNewApplicationInstance)`
/// tuple produced by each launch-mode branch without ever asking `NSWorkspace` to open
/// anything.
///
/// `OpenCall.mode` distinguishes between the two NSWorkspace entry points so JetBrains-family
/// launches (which must route through `openApplication(at:configuration:)` to deliver
/// arguments) can be asserted distinctly from `.directory` launches that go through
/// `open(urls:withApplicationAt:configuration:)` with an actual URL list.
final class RecordingAppLauncher: AppLauncher, @unchecked Sendable {
  /// Bundle IDs that should appear installed. Map keys are bundle IDs; values are the app
  /// URLs the launcher will return from `urlForApplication(bundleIdentifier:)`.
  var installedApps: [String: URL] = [:]
  /// Recorded invocations of both `open(urls:withApplicationAt:configuration:)` and
  /// `openApplication(at:configuration:)`, tagged by `mode`.
  private(set) var openCalls: [OpenCall] = []
  /// When set, the next `open` / `openApplication` call throws this error.
  var openError: Error?

  enum Mode: Sendable, Equatable {
    /// `NSWorkspace.open(_:withApplicationAt:configuration:)` — `.directory` launches.
    case openURLs
    /// `NSWorkspace.openApplication(at:configuration:)` — `.applicationWithArguments`
    /// launches. `urls` is always empty for this mode.
    case openApplication
  }

  struct OpenCall: Sendable {
    let mode: Mode
    let urls: [URL]
    let appURL: URL
    let arguments: [String]
    let createsNewApplicationInstance: Bool
  }

  init(installedApps: [String: URL] = [:]) {
    self.installedApps = installedApps
  }

  func urlForApplication(bundleIdentifier: String) -> URL? {
    installedApps[bundleIdentifier]
  }

  func open(
    urls: [URL],
    withApplicationAt appURL: URL,
    configuration: NSWorkspace.OpenConfiguration
  ) async throws {
    openCalls.append(
      OpenCall(
        mode: .openURLs,
        urls: urls,
        appURL: appURL,
        arguments: configuration.arguments,
        createsNewApplicationInstance: configuration.createsNewApplicationInstance
      )
    )
    if let openError { throw openError }
  }

  func openApplication(
    at appURL: URL,
    configuration: NSWorkspace.OpenConfiguration
  ) async throws {
    openCalls.append(
      OpenCall(
        mode: .openApplication,
        urls: [],
        appURL: appURL,
        arguments: configuration.arguments,
        createsNewApplicationInstance: configuration.createsNewApplicationInstance
      )
    )
    if let openError { throw openError }
  }
}

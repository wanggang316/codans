import AppKit
import ComposableArchitecture
import Foundation

/// Thin TCA dependency over `NSWorkspace.activateFileViewerSelecting`. The
/// sidebar's "Reveal in Finder" context-menu item dispatches a delegate action
/// that `RootFeature` routes here, so reducers stay free of AppKit imports and
/// TestStore can assert the call path via an override.
///
/// `liveValue` is a concrete bridge rather than the `fatalError(...)` pattern
/// used by clients that need runtime wiring — `NSWorkspace.shared` is always
/// available on macOS, so there's no `.withDependencies` ceremony required at
/// app startup.
nonisolated struct FinderClient: Sendable {
  var reveal: @MainActor @Sendable (_ path: String) -> Void
}

extension FinderClient: DependencyKey {
  static let liveValue = FinderClient(
    reveal: { path in
      let url = URL(fileURLWithPath: path)
      NSWorkspace.shared.activateFileViewerSelecting([url])
    }
  )

  static let testValue = FinderClient(
    reveal: unimplemented("FinderClient.reveal")
  )
}

extension DependencyValues {
  var finderClient: FinderClient {
    get { self[FinderClient.self] }
    set { self[FinderClient.self] = newValue }
  }
}

import Foundation
import CodansCore

@testable import Codans

// swiftlint:disable async_without_await
//
// The conforming members below are `async` because the production
// `OSNotifier` protocol requires it; the mock has no real async work to do.

/// Test double for `OSNotifier`. M2.T2 added the `playSound:` parameter to
/// `post`; the recorded tuples preserve both the entry and the flag so
/// `NotificationCoordinatorTests` can assert on either dimension.
@MainActor
final class MockOSNotifier: OSNotifier {
  var status: AuthorizationStatus = .authorized
  private(set) var posts: [(entry: InboxEntry, playSound: Bool, sourceLabel: String?)] = []

  func currentAuthorizationStatus() async -> AuthorizationStatus { status }

  func requestAuthorization() async -> AuthorizationStatus { status }

  func post(_ entry: InboxEntry, playSound: Bool, sourceLabel: String?) async {
    posts.append((entry, playSound, sourceLabel))
  }
}
// swiftlint:enable async_without_await

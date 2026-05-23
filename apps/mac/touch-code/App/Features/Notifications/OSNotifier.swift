import AppKit
import Foundation
import Observation
import TouchCodeCore
@preconcurrency import UserNotifications

/// Three-state mirror of `UNAuthorizationStatus` reduced to the cases the
/// app actually distinguishes. `.provisional` collapses into `.authorized`
/// because both states can deliver content; `.ephemeral` does the same.
public enum AuthorizationStatus: String, Sendable, Codable {
  case notDetermined
  case authorized
  case denied
}

/// Adapter protocol over `UNUserNotificationCenter` so the detector can be
/// tested without a live notification daemon. `post` is a silent no-op when
/// the status is `.denied`; the inbox + Dock badge continue to work.
///
/// One live instance per app process — held by `AppState.osNotifier` and
/// also forwarded to `NotificationsSettingsView` via `@Environment` so
/// the recovery panel does not spawn a parallel notifier (each `init`
/// re-runs `setNotificationCategories` on the shared center).
@MainActor
public protocol OSNotifier: AnyObject {
  func currentAuthorizationStatus() async -> AuthorizationStatus
  func requestAuthorization() async -> AuthorizationStatus
  /// Posts a system banner for `entry`. `playSound` mirrors
  /// `NotificationsSettings.soundEnabled` at the moment the coordinator
  /// (M2.T2) decided to surface this entry; the live SettingsStore value
  /// is intentionally read once at the call site rather than re-read here
  /// so a same-tick toggle flip cannot race the banner build.
  func post(_ entry: InboxEntry, playSound: Bool) async
}

/// Production adapter. On the first `post` after a `.notDetermined` boot the
/// system authorization prompt fires; subsequent posts respect the user's
/// answer. Banner click forwards to `AppDelegate`'s
/// `userNotificationCenter(_:didReceive:withCompletionHandler:)`, which
/// parses `userInfo["deeplink"]` and dispatches `RootFeature.focusHierarchyPath`.
@MainActor
@Observable
public final class UserNotificationsOSNotifier: OSNotifier {
  @ObservationIgnored private let center: UNUserNotificationCenter

  public init(center: UNUserNotificationCenter = .current()) {
    self.center = center
    registerCategories()
  }

  public func currentAuthorizationStatus() async -> AuthorizationStatus {
    let settings = await center.notificationSettings()
    return Self.map(settings.authorizationStatus)
  }

  public func requestAuthorization() async -> AuthorizationStatus {
    do {
      _ = try await center.requestAuthorization(options: [.alert, .badge, .sound])
    } catch {
      // Authorization-request failure falls through to the status refetch
      // below — the refetch is the source of truth for the final state.
    }
    return await currentAuthorizationStatus()
  }

  public func post(_ entry: InboxEntry, playSound: Bool) async {
    var status = await currentAuthorizationStatus()
    if status == .notDetermined {
      status = await requestAuthorization()
    }
    guard status == .authorized else { return }

    let content = UNMutableNotificationContent()
    content.title = entry.title
    content.body = entry.body
    content.threadIdentifier = entry.source.paneID.raw.uuidString
    content.categoryIdentifier = entry.kind.rawValue
    content.sound = playSound ? .default : nil
    content.userInfo = ["deeplink": Self.deeplink(for: entry.source).absoluteString]

    let request = UNNotificationRequest(
      identifier: entry.id.raw.uuidString,
      content: content,
      trigger: nil
    )
    try? await center.add(request)
  }

  // MARK: - Deeplink

  /// `touch-code://focus?project=...&worktree=...&tab=...&pane=...`. Parsed
  /// in `AppDelegate.userNotificationCenter(_:didReceive:...)` to recover the
  /// originating `(projectID, worktreeID, tabID, paneID)` tuple.
  public static func deeplink(for source: InboxEntry.SourcePath) -> URL {
    var components = URLComponents()
    components.scheme = "touch-code"
    components.host = "focus"
    components.queryItems = [
      URLQueryItem(name: "project", value: source.projectID.raw.uuidString),
      URLQueryItem(name: "worktree", value: source.worktreeID.raw.uuidString),
      URLQueryItem(name: "tab", value: source.tabID.raw.uuidString),
      URLQueryItem(name: "pane", value: source.paneID.raw.uuidString),
    ]
    // `URLComponents.url` cannot fail here — every component is statically
    // valid — but the API is optional, so fall back to a non-encoded form.
    return components.url ?? URL(string: "touch-code://focus")!
  }

  // MARK: - Category registration

  private func registerCategories() {
    // v1 has no per-banner action buttons; the only interaction is "click
    // the banner". Categories exist solely so threadIdentifier grouping
    // works; one category per `InboxEntry.Kind`.
    let categories: Set<UNNotificationCategory> = Set(
      InboxEntry.Kind.allCases.map { kind in
        UNNotificationCategory(
          identifier: kind.rawValue,
          actions: [],
          intentIdentifiers: [],
          options: []
        )
      }
    )
    center.setNotificationCategories(categories)
  }

  private static func map(_ status: UNAuthorizationStatus) -> AuthorizationStatus {
    switch status {
    case .notDetermined: return .notDetermined
    case .denied: return .denied
    case .authorized, .ephemeral, .provisional: return .authorized
    @unknown default: return .denied
    }
  }
}

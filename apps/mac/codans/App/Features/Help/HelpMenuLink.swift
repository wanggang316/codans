import Foundation

/// The help links shown by the sidebar footer's help menu and the menubar
/// Help menu. Both menus render `allCases` through `HelpMenuItems`, so the
/// two entry points cannot drift apart. Case order is menu order.
enum HelpMenuLink: CaseIterable, Hashable {
  case website
  case reportIssue
  case changelog

  var title: String {
    switch self {
    case .website: return "Website"
    case .reportIssue: return "Report issue"
    case .changelog: return "Changelog"
    }
  }

  var systemImage: String {
    switch self {
    case .website: return "globe"
    case .reportIssue: return "exclamationmark.bubble"
    case .changelog: return "list.bullet.rectangle"
    }
  }

  func url(in environment: HelpEnvironment) -> URL {
    switch self {
    case .website: return Self.websiteURL
    case .reportIssue: return Self.reportIssueURL(for: environment)
    case .changelog: return Self.changelogURL
    }
  }

  private static let websiteURL = URL(string: "https://codans.dev")!
  private static let changelogURL = URL(string: "https://codans.dev/changelog")!
  private static let newIssueURL = "https://github.com/wanggang316/codans/issues/new"

  /// Body text prefilled in the new GitHub issue. The user can edit it
  /// before they submit the issue.
  static func issueBody(for environment: HelpEnvironment) -> String {
    """
    <!-- Describe the issue: what happened, what you expected, and the steps to reproduce it. -->



    ---
    - codans: \(environment.appVersion) (\(environment.appBuild))
    - macOS: \(environment.macOSVersion)
    - Architecture: \(environment.architecture)
    """
  }

  private static func reportIssueURL(for environment: HelpEnvironment) -> URL {
    // `URLComponents.queryItems` leaves `&`, `=`, `+` raw because they are
    // legal in a query, but GitHub then splits or misreads the body. Encode
    // everything except RFC 3986 unreserved characters.
    let body =
      issueBody(for: environment)
      .addingPercentEncoding(withAllowedCharacters: queryValueAllowed) ?? ""
    return URL(string: "\(newIssueURL)?body=\(body)")!
  }

  private static let queryValueAllowed = CharacterSet(
    charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
}

/// Facts about the running app and machine that go into a bug report.
struct HelpEnvironment: Equatable {
  var appVersion: String
  var appBuild: String
  var macOSVersion: String
  var architecture: String

  static var current: HelpEnvironment {
    let info = Bundle.main.infoDictionary
    let os = ProcessInfo.processInfo.operatingSystemVersion
    return HelpEnvironment(
      appVersion: info?["CFBundleShortVersionString"] as? String ?? "unknown",
      appBuild: info?["CFBundleVersion"] as? String ?? "unknown",
      macOSVersion: "\(os.majorVersion).\(os.minorVersion).\(os.patchVersion)",
      architecture: currentArchitecture
    )
  }

  private static var currentArchitecture: String {
    #if arch(arm64)
      return "arm64"
    #elseif arch(x86_64)
      return "x86_64"
    #else
      return "unknown"
    #endif
  }
}

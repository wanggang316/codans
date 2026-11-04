import Foundation

/// The icon of a Host row: an SF Symbol for a computer or server. Stored on
/// `HostRecord.icon`; a record with no icon shows `.server`. This Mac has no
/// record and shows the symbol of the machine model (`forMacModel(_:)`).
///
/// Codable shape is the raw value. The raw values are stable keys, not
/// symbol names, so a symbol can change without a catalog migration.
public nonisolated enum HostIcon: String, CaseIterable, Codable, Hashable, Sendable, Identifiable {
  case globe
  case server
  case cloud
  case macBook = "macbook"
  case macMini = "mac-mini"
  case macStudio = "mac-studio"
  case desktop

  /// The icon a Host with no icon shows.
  public static let fallback: HostIcon = .server

  public var id: String { rawValue }

  public var systemImage: String {
    switch self {
    case .globe: "globe"
    case .server: "server.rack"
    case .cloud: "icloud"
    case .macBook: "laptopcomputer"
    case .macMini: "macmini"
    case .macStudio: "macstudio"
    case .desktop: "desktopcomputer"
    }
  }

  public var displayName: String {
    switch self {
    case .globe: "Globe"
    case .server: "Server"
    case .cloud: "Cloud"
    case .macBook: "MacBook"
    case .macMini: "Mac mini"
    case .macStudio: "Mac Studio"
    case .desktop: "Desktop"
    }
  }

  /// The icon for a Mac model. `model` is the product name ("Mac mini
  /// (2024)", "MacBook Pro (14-inch, 2023)") or the model identifier of an
  /// Intel Mac ("MacBookPro16,1", "Macmini8,1"). Any other Mac is a desktop.
  public static func forMacModel(_ model: String) -> HostIcon {
    let key = model.lowercased().replacingOccurrences(of: " ", with: "")
    if key.hasPrefix("macbook") { return .macBook }
    if key.hasPrefix("macmini") { return .macMini }
    if key.hasPrefix("macstudio") { return .macStudio }
    return .desktop
  }
}

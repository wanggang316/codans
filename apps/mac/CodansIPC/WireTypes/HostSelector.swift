import CodansCore
import Foundation

extension IPC {
  /// A Host as the CLI and IPC spell it (ADR 0006): a Host record id, or
  /// `0` for This Mac. The same string is the `--host` value, the
  /// `hostID` of `hierarchy.resolveAlias`, and the `host.id` of every
  /// output that shows a Project, so a script can copy one into the other.
  public enum HostSelector: Hashable, Sendable, CustomStringConvertible {
    case thisMac
    case host(HostID)

    public static let thisMacValue = "0"

    /// `0` or a UUID; any other value (the empty string included, so an
    /// unset shell variable does not select This Mac) is nil.
    public init?(_ value: String) {
      if value == Self.thisMacValue {
        self = .thisMac
      } else if let uuid = UUID(uuidString: value) {
        self = .host(HostID(raw: uuid))
      } else {
        return nil
      }
    }

    /// The Host `project` is on.
    public init(project: Project) {
      self = project.hostID.map { .host($0) } ?? .thisMac
    }

    public var description: String {
      switch self {
      case .thisMac: Self.thisMacValue
      case .host(let id): id.raw.uuidString
      }
    }

    public func matches(_ project: Project) -> Bool {
      Self(project: project) == self
    }
  }
}

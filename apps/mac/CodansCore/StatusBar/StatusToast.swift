import Foundation

/// Short-lived outcome notice shown in the Worktree Status Bar (titlebar
/// center slot): "this just finished" or "this just failed".
///
/// Two severities, each auto-cleared by the owning reducer (3 s / 8 s in
/// `StatusBarFeature`). Work that is still running is a `StatusActivity`, not
/// a toast — a toast has no owner to end it. `error` is intentionally absent:
/// fatal errors route through sheets/banners, not a one-line slot that the
/// next push can cover.
///
/// Lives in `CodansCore` so any feature can construct values without
/// depending on the app target.
public nonisolated enum StatusToast: Equatable, Sendable {
  case success(String)
  case warning(String)

  public var message: String {
    switch self {
    case .success(let m), .warning(let m): return m
    }
  }

  /// Warning for a failed user action, phrased `"<action> failed: <reason>"`.
  /// `reason` is squeezed to its first line so raw stderr or a multi-line
  /// `localizedDescription` never floods the slot.
  public static func failure(_ action: String, reason: String) -> StatusToast {
    let line = oneLine(reason)
    return .warning(line.isEmpty ? "\(action) failed" : "\(action) failed: \(line)")
  }

  /// `failure(_:reason:)` with the error's `localizedDescription`.
  public static func failure(_ action: String, error: any Error) -> StatusToast {
    failure(action, reason: error.localizedDescription)
  }

  /// First non-empty line of `raw`, trimmed.
  public static func oneLine(_ raw: String) -> String {
    raw.split(whereSeparator: \.isNewline)
      .lazy
      .map { $0.trimmingCharacters(in: .whitespaces) }
      .first { !$0.isEmpty } ?? ""
  }

  /// Characters the status slot shows before truncating; the rest stays
  /// reachable through the slot's tooltip.
  public static let maxDisplayLength = 80

  /// `message` capped at `maxDisplayLength` with a trailing ellipsis. The
  /// slot sizes itself from its ideal width, so an uncapped line would make
  /// it fall back to the glyph-only form instead of truncating.
  public var displayMessage: String {
    guard message.count > Self.maxDisplayLength else { return message }
    return String(message.prefix(Self.maxDisplayLength - 1)) + "…"
  }
}

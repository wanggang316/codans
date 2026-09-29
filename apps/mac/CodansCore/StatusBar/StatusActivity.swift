import Foundation

/// A user-initiated operation that is still running, shown in the Worktree
/// Status Bar until its emitter ends it.
///
/// Several activities can run at once. The status bar shows the most recently
/// begun one with a count of the rest; its popover lists them all. An activity
/// never expires on its own, so every begin needs an end on every exit path —
/// including cancellation, where the canceller ends it.
public nonisolated struct StatusActivity: Identifiable, Equatable, Sendable {
  public enum Progress: Equatable, Sendable {
    case indeterminate
    case determinate(completed: Int, total: Int)

    /// Completed share in `0...1`, nil when indeterminate or `total <= 0`.
    public var fraction: Double? {
      guard case .determinate(let completed, let total) = self, total > 0 else { return nil }
      return min(max(Double(completed) / Double(total), 0), 1)
    }
  }

  public let id: StatusActivityID
  /// Present-participle phrase naming the work: "Merging PR #12".
  public var title: String
  /// Secondary state such as "Waiting for Claude". Determinate progress shows
  /// `completed/total` when this is nil.
  public var detail: String?
  public var progress: Progress
  /// Whether the popover offers Stop. The emitter must handle the resulting
  /// cancel request by actually stopping the work.
  public var isCancellable: Bool

  public init(
    id: StatusActivityID,
    title: String,
    detail: String? = nil,
    progress: Progress = .indeterminate,
    isCancellable: Bool = false
  ) {
    self.id = id
    self.title = title
    self.detail = detail
    self.progress = progress
    self.isCancellable = isCancellable
  }

  /// Text after the title: `detail`, else the determinate count, else nil.
  public var detailText: String? {
    if let detail, !detail.isEmpty { return detail }
    if case .determinate(let completed, let total) = progress { return "\(completed)/\(total)" }
    return nil
  }

  /// Single-line form for the status slot: `"Title | detail"`.
  public var summary: String {
    guard let detailText else { return title }
    return "\(title) | \(detailText)"
  }
}

/// Stable key for one running operation: a domain plus the key that makes
/// the operation unique (`"pr.mutation"` + worktree id), so a second begin
/// for the same operation replaces the first instead of stacking.
public nonisolated struct StatusActivityID: Hashable, Sendable, CustomStringConvertible {
  public let domain: String
  public let key: String?

  public init(_ domain: String, _ key: (any CustomStringConvertible)? = nil) {
    self.domain = domain
    self.key = key.map { "\($0)" }
  }

  public var description: String { key.map { "\(domain):\($0)" } ?? domain }
}

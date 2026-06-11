import Foundation

/// Reason a candidate notification was suppressed before reaching any sink.
/// Shared between `PaneAttentionInterpreter.Step.drop` (pure interpreter
/// suppressions) and `NotificationCoordinator.Decision.dropped` (app-layer
/// policy suppressions). Case set is intentionally union of both layers; not
/// every value is emitted by every layer.
public nonisolated enum InboxDropReason: String, Equatable, Sendable, Codable {
  case sourceIsFocused  // coordinator only
  case inAppDisabled  // coordinator only
  case systemDisabled  // coordinator only
  case paneMuted  // detector-side; coordinator never sees these
  case commandFinishedDisabled  // interpreter only
  case commandFinishedShort  // interpreter only
  case commandCancelled  // interpreter only
  case userTypingRecently  // interpreter only
  case authorizationDenied  // coordinator only
}

import Foundation

/// Final decision of a Pull Request's review process. Optional at the field level — a
/// Pull Request with no required reviewers has a nil decision, which is different from
/// `.reviewRequired` (a decision that actively blocks merge).
///
/// Provider-neutral: each Git Platform's decoding layer maps its wire values into these
/// cases. Raw values are the snapshot-cache form.
public nonisolated enum ReviewDecision: String, Codable, Sendable, CaseIterable {
  case approved
  case changesRequested
  case reviewRequired
}

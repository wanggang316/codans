import Foundation

/// The agent-authored half of a handoff: a markdown document the outgoing
/// agent writes from its working context. codans never authors this prose —
/// it only validates the shape and installs the file.
public nonisolated enum HandoffBriefing {
  /// The skeleton a briefing follows. Referenced by error messages and the
  /// request typed into the source pane; never written to disk by codans.
  public static let sectionSkeleton = [
    "# Handoff",
    "## Objective",
    "## Current State",
    "## What Has Been Done",
    "## Open Questions",
    "## Risks / Watch Out",
    "## Next Steps",
    "## Suggested Prompt For Next Agent",
  ]

  /// The sections a briefing must carry to be installed. Everything else in
  /// the skeleton is recommended, not enforced.
  public static let requiredSections = ["## Objective", "## Current State", "## Next Steps"]

  /// Normalises agent-authored text into the artifact written to
  /// `current.md`, or `nil` when it is unusable (empty after unwrapping, or
  /// missing a required section). Only chat wrapping is stripped; the body
  /// is kept verbatim.
  public static func validated(_ raw: String) -> String? {
    let text = MarkdownDocumentNormalizer.normalized(raw)
    guard !text.isEmpty, MarkdownDocumentNormalizer.hasSections(requiredSections, in: text) else {
      return nil
    }
    return text + "\n"
  }
}

/// Where a transition's briefing comes from. The entry point decides, the
/// coordinator executes: the live source agent either supplies its briefing
/// inline or the caller explicitly opts into a context-only transition.
/// There is no third path — codans never starts a hidden model turn to
/// synthesise a briefing on the agent's behalf.
public nonisolated enum HandoffBriefingSource: Equatable, Sendable {
  /// Agent-authored text supplied with the command. Invalid text throws
  /// before any filesystem side effect.
  case inline(String)
  /// Intentionally context-only.
  case none
}

/// How the briefing was (or was not) obtained. `current.md` exists iff a
/// validated briefing produced it, so this value is the whole story of the
/// semantic side of a handoff.
public nonisolated enum HandoffBriefingOutcome: String, Equatable, Sendable, Codable {
  case inline
  case none

  /// A validated briefing was written for this outcome.
  public var wroteBriefing: Bool { self == .inline }
}

/// A briefing validated before the handoff's irreversible artifact work
/// begins, so an invalid one is rejected with zero side effects.
public nonisolated struct HandoffPreparedBriefing: Equatable, Sendable {
  public let artifact: String?
  public let outcome: HandoffBriefingOutcome

  public init(artifact: String?, outcome: HandoffBriefingOutcome) {
    self.artifact = artifact
    self.outcome = outcome
  }

  public static let contextOnly = HandoffPreparedBriefing(artifact: nil, outcome: .none)

  /// Resolves a source to validated artifact text. Inline text that fails
  /// validation throws `HandoffError.invalidBriefing`.
  public init(source: HandoffBriefingSource) throws {
    switch source {
    case .inline(let raw):
      guard let artifact = HandoffBriefing.validated(raw) else {
        throw HandoffError.invalidBriefing
      }
      self.init(artifact: artifact, outcome: .inline)
    case .none:
      self = .contextOnly
    }
  }
}

public nonisolated enum HandoffError: Error, Equatable, Sendable {
  /// Inline briefing text failed validation; nothing was written.
  case invalidBriefing
}

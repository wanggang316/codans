import Foundation
import Testing
import TouchCodeCore

@testable import TouchCode

/// Scorer ranks items against a query. Tests are organized by the property
/// they verify: band ordering (contiguous > subsequence title > subtitle),
/// prefix and separator bonuses, quoted-contiguous mode, recency blend,
/// empty-query gating, and determinism.
@MainActor
struct CommandPaletteFuzzyScorerTests {
  private static func item(
    id: String = "test.item",
    title: String,
    subtitle: String? = nil,
    priorityTier: Int = 100,
    hiddenWhenQueryEmpty: Bool = false
  ) -> CommandPaletteItem {
    CommandPaletteItem(
      id: id,
      title: title,
      subtitle: subtitle,
      icon: "circle",
      priorityTier: priorityTier,
      hiddenWhenQueryEmpty: hiddenWhenQueryEmpty,
      kind: .openSettings
    )
  }

  private static func score(
    _ item: CommandPaletteItem,
    query: String,
    recency: [String: TimeInterval] = [:],
    now: TimeInterval = 0
  ) -> Int? {
    CommandPaletteFuzzyScorer.score(
      item: item, query: query, recency: recency, now: now
    )
  }

  // MARK: - Band ordering

  @Test
  func contiguousOutranksSubsequence() {
    let contiguous = Self.item(title: "Toggle Git Viewer")
    let subsequence = Self.item(title: "Toggle Gxt Vxxxer")
    let a = Self.score(contiguous, query: "git")
    let b = Self.score(subsequence, query: "gtv")
    #expect(a != nil && b != nil)
    #expect(a! > b!)
  }

  @Test
  func titleOutranksSubtitleWhenBothSubsequenceMatch() {
    let titleHit = Self.item(title: "Refresh Worktree")
    let subtitleHit = Self.item(title: "Do Something", subtitle: "Refresh Worktree")
    let a = Self.score(titleHit, query: "rfsh")
    let b = Self.score(subtitleHit, query: "rfsh")
    #expect(a != nil && b != nil)
    #expect(a! > b!)
  }

  @Test
  func nonMatchReturnsNil() {
    let item = Self.item(title: "Open Settings")
    #expect(Self.score(item, query: "git") == nil)
  }

  // MARK: - Position + separator bonuses

  @Test
  func prefixMatchOutranksSuffixMatchWithinContiguousBand() {
    let prefix = Self.item(title: "Open Settings")
    let suffix = Self.item(title: "Nope Close Open")
    let a = Self.score(prefix, query: "ope")
    let b = Self.score(suffix, query: "ope")
    #expect(a != nil && b != nil)
    #expect(a! > b!)
  }

  @Test
  func separatorBonusBumpsSubsequenceMatch() {
    // Both titles are *subsequence-only* matches for "nt" — neither
    // contains the contiguous substring "nt". `wordStart` has both
    // characters at word boundaries, so the scorer's DP path must pick
    // them over any earlier non-boundary 'n'.
    let noSeparator = Self.item(title: "Neurotic")
    let wordStart = Self.item(title: "Open New Tab")
    let a = Self.score(noSeparator, query: "nt")
    let b = Self.score(wordStart, query: "nt")
    #expect(a != nil && b != nil)
    #expect(b! > a!)
  }

  // MARK: - Quoted contiguous mode

  @Test
  func quotedQueryRequiresContiguousMatch() {
    let contiguous = Self.item(title: "Open Git Viewer")
    let subsequence = Self.item(title: "Groom Inner Tab")
    #expect(Self.score(contiguous, query: "\"git\"") != nil)
    // `git` is a valid subsequence in "Groom Inner Tab" (g…i…t) but not a
    // contiguous substring, so quoted mode must reject it.
    #expect(Self.score(subsequence, query: "\"git\"") == nil)
  }

  // MARK: - Recency

  @Test
  func recencyReordersWithinABand() {
    let a = Self.item(id: "cmd.a", title: "Alpha Command")
    let b = Self.item(id: "cmd.b", title: "Alpha Command Also")
    let now: TimeInterval = 1_700_000_000
    // Neither is contiguous-matched on "ap"; both subsequence-match ("a…p")
    // with roughly identical body bonuses. `a` has recent activation → wins.
    let recency: [String: TimeInterval] = ["cmd.a": now - 60]
    let aScore = Self.score(a, query: "ap", recency: recency, now: now)
    let bScore = Self.score(b, query: "ap", recency: recency, now: now)
    #expect(aScore != nil && bScore != nil)
    #expect(aScore! > bScore!)
  }

  @Test
  func recencyCannotFlipBands() {
    let contiguous = Self.item(id: "cmd.contig", title: "Toggle Git Viewer")
    let subsequence = Self.item(id: "cmd.subseq", title: "Gxt Vxxxer Xx")
    let now: TimeInterval = 1_700_000_000
    // The subsequence match has fresh recency (1-min-ago); the contiguous
    // match has none. Contiguous must still outrank it.
    let recency: [String: TimeInterval] = ["cmd.subseq": now - 60]
    let a = Self.score(contiguous, query: "git")
    let b = Self.score(subsequence, query: "gv", recency: recency, now: now)
    #expect(a != nil && b != nil)
    #expect(a! > b!)
  }

  @Test
  func recencyDecaysToZeroBeyond30Days() {
    let item = Self.item(id: "cmd.x", title: "Alpha")
    let now: TimeInterval = 1_700_000_000
    let fresh: [String: TimeInterval] = ["cmd.x": now - 60]
    let stale: [String: TimeInterval] = ["cmd.x": now - 60 * 86_400]  // 60 days ago
    let a = Self.score(item, query: "", recency: fresh, now: now)
    let b = Self.score(item, query: "", recency: stale, now: now)
    #expect(a != nil && b != nil)
    #expect(a! > b!)
    // Stale recency contributes nothing, so it matches the bare empty-query score.
    let bare = Self.score(item, query: "", recency: [:], now: now)
    #expect(b == bare)
  }

  // MARK: - Empty query gating

  @Test
  func emptyQueryHidesHiddenWhenQueryEmptyItems() {
    let normal = Self.item(id: "a", title: "Normal")
    let hidden = Self.item(id: "b", title: "Sharp-edge", hiddenWhenQueryEmpty: true)
    #expect(Self.score(normal, query: "") != nil)
    #expect(Self.score(hidden, query: "") == nil)
  }

  @Test
  func emptyQuerySurfacesHiddenItemsWhenSearched() {
    let hidden = Self.item(id: "b", title: "Close Current Worktree", hiddenWhenQueryEmpty: true)
    #expect(Self.score(hidden, query: "close") != nil)
  }

  // MARK: - Determinism

  @Test
  func scoreIsDeterministicOnIdenticalInput() {
    let item = Self.item(title: "Toggle Git Viewer")
    let r1 = Self.score(item, query: "git")
    let r2 = Self.score(item, query: "git")
    let r3 = Self.score(item, query: "git")
    #expect(r1 == r2 && r2 == r3)
  }
}

import SwiftUI
import CodansCore

/// Compact four-colour ring summarising a PR's check rollup. Rendered at a
/// fixed diameter so it fits in the toolbar's principal slot without
/// disturbing the surrounding row height.
///
/// Segments are laid out clockwise starting at 12 o'clock:
///   * passing   — `CheckRollupColor.passing`
///   * failing   — `CheckRollupColor.failing`
///   * pending   — `CheckRollupColor.pending`
///   * neutral   — `CheckRollupColor.neutral`
///
/// Returns `EmptyView` when the list is empty — a PR with zero check runs
/// should collapse to badge-only rendering rather than draw an empty stroke.
struct ChecksRollupRing: View {
  let checks: [CheckResult]
  var diameter: CGFloat = 14
  var strokeWidth: CGFloat = 3

  var body: some View {
    let breakdown = Breakdown(checks: checks)
    if breakdown.total == 0 {
      EmptyView()
    } else {
      Canvas { context, size in
        let rect = CGRect(
          x: strokeWidth / 2,
          y: strokeWidth / 2,
          width: size.width - strokeWidth,
          height: size.height - strokeWidth
        )
        var cursor: CGFloat = -90  // 12 o'clock
        for segment in breakdown.orderedSegments where segment.count > 0 {
          let sweep = CGFloat(segment.count) / CGFloat(breakdown.total) * 360
          let path = Path { p in
            p.addArc(
              center: CGPoint(x: size.width / 2, y: size.height / 2),
              radius: rect.width / 2,
              startAngle: .degrees(Double(cursor)),
              endAngle: .degrees(Double(cursor + sweep)),
              clockwise: false
            )
          }
          context.stroke(
            path,
            with: .color(segment.color),
            style: StrokeStyle(lineWidth: strokeWidth, lineCap: .butt)
          )
          cursor += sweep
        }
      }
      .frame(width: diameter, height: diameter)
      .accessibilityElement(children: .ignore)
      .accessibilityLabel("Checks")
      .accessibilityValue(breakdown.accessibilityValue)
    }
  }
}

extension ChecksRollupRing {
  /// Pure counts view of a check list. Kept internal + `Equatable` so a unit
  /// test can pin segment counts without stubbing SwiftUI geometry.
  struct Breakdown: Equatable {
    var passing: Int = 0
    var failing: Int = 0
    var pending: Int = 0
    var neutral: Int = 0

    /// Failure conclusions that must paint a check red. Mirrors
    /// `PullRequestBadge.CheckRollup.failingConclusions` (the sidebar badge
    /// uses the same list via the rollup enum). Duplicated here instead of
    /// exposing the private static — the list is short, concrete, and
    /// unlikely to diverge; breakage on diverge would show up immediately
    /// as a visual mismatch between sidebar and titlebar.
    private static let failingConclusions: Set<CheckConclusion> = [
      .failure, .cancelled, .timedOut, .actionRequired, .stale, .startupFailure,
    ]

    init(checks: [CheckResult]) {
      for check in checks {
        switch check.status {
        case .queued, .inProgress, .waiting, .pending:
          pending += 1
        case .completed:
          guard let conclusion = check.conclusion else {
            neutral += 1
            continue
          }
          if Self.failingConclusions.contains(conclusion) {
            failing += 1
          } else if conclusion == .success {
            passing += 1
          } else {
            // .skipped / .neutral — informational, not a failure
            neutral += 1
          }
        }
      }
    }

    var total: Int { passing + failing + pending + neutral }

    /// Segments in draw order (clockwise from 12 o'clock).
    var orderedSegments: [(count: Int, color: Color)] {
      [
        (passing, CheckRollupColor.passing),
        (failing, CheckRollupColor.failing),
        (pending, CheckRollupColor.pending),
        (neutral, CheckRollupColor.neutral),
      ]
    }

    var accessibilityValue: String {
      var parts: [String] = []
      if passing > 0 { parts.append("\(passing) passing") }
      if failing > 0 { parts.append("\(failing) failing") }
      if pending > 0 { parts.append("\(pending) pending") }
      if neutral > 0 { parts.append("\(neutral) neutral") }
      return parts.joined(separator: ", ")
    }
  }
}

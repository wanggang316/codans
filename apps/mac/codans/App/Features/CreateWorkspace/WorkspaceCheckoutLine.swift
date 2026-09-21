import SwiftUI

/// What a checkout will be, or is, on disk, as both checkout lists (the
/// New Workspace sheet and a workspace's settings) describe it: the kind of
/// checkout, the branch, and the ref it relates to. Pure value so the
/// reducer derives it and tests read it without a view.
nonisolated enum WorkspaceCheckoutDescription: Equatable, Sendable {
  /// What a remote-tracking checkout does about a local branch of the same
  /// name.
  enum LocalBranch: Equatable, Sendable {
    /// None exists; one is created.
    case none
    case kept
    case reset
  }

  /// A branch to create from `base`. Nil `branch`: named after the title.
  case newBranch(branch: String?, base: String)
  /// A local branch checked out as it is. Nil: none chosen yet.
  case existingBranch(String?)
  /// A remote-tracking ref checked out as a local branch of the same name.
  case trackingRemote(branch: String, remoteRef: String, local: LocalBranch)
  /// A checkout that exists, as the catalog knows it. Nil: detached HEAD.
  case checkedOut(branch: String?)

  /// The one-sentence form, for accessibility and the tests.
  var summary: String {
    switch self {
    case .newBranch(nil, let base):
      return "New branch from \(base), named after the title"
    case .newBranch(let branch?, let base):
      return "New branch \(branch) from \(base)"
    case .existingBranch(nil):
      return "Existing branch"
    case .existingBranch(let branch?):
      return "Branch \(branch)"
    case .trackingRemote(let branch, let remoteRef, .none):
      return "Branch \(branch), tracking \(remoteRef)"
    case .trackingRemote(let branch, let remoteRef, .kept):
      return "Local branch \(branch), tracking \(remoteRef)"
    case .trackingRemote(let branch, let remoteRef, .reset):
      return "Branch \(branch), reset to \(remoteRef)"
    case .checkedOut(nil):
      return "Detached"
    case .checkedOut(let branch?):
      return "Branch \(branch)"
    }
  }

  /// The badge naming the kind of checkout; none for a plain existing
  /// checkout, where the branch says it all.
  var badge: (title: String, tint: Color)? {
    switch self {
    case .newBranch: return ("New", .green)
    case .existingBranch: return ("Existing", .secondary)
    case .trackingRemote(_, _, .none), .trackingRemote(_, _, .kept): return ("Remote", .blue)
    case .trackingRemote(_, _, .reset): return ("Reset", .orange)
    case .checkedOut(nil): return ("Detached", .secondary)
    case .checkedOut: return nil
    }
  }

  var branch: String? {
    switch self {
    case .newBranch(let branch, _), .existingBranch(let branch), .checkedOut(let branch): return branch
    case .trackingRemote(let branch, _, _): return branch
    }
  }

  /// Stands where the branch would be while there is none to name.
  var branchPlaceholder: String? {
    switch self {
    case .newBranch(nil, _): return "Named after the title"
    case .existingBranch(nil): return "Choose a branch"
    case .checkedOut(nil): return "No branch"
    default: return nil
    }
  }

  /// How the branch relates to another ref: the word, then the ref.
  var relation: (word: String, ref: String)? {
    switch self {
    case .newBranch(_, let base): return ("from", base)
    case .trackingRemote(_, let remoteRef, .reset): return ("reset to", remoteRef)
    case .trackingRemote(_, let remoteRef, _): return ("tracking", remoteRef)
    case .existingBranch, .checkedOut: return nil
    }
  }

  var note: String? {
    if case .trackingRemote(_, _, .kept) = self { return "local branch kept" }
    return nil
  }
}

/// One line describing a checkout: its badge, then the branch with the
/// branch glyph, then what it comes from or tracks. Refs read in the
/// primary color and the words between them in the secondary one, so the
/// identifiers stand out from the prose.
struct WorkspaceCheckoutLine: View {
  let checkout: WorkspaceCheckoutDescription

  var body: some View {
    HStack(spacing: 6) {
      if let badge = checkout.badge {
        WorkspaceCheckoutBadge(title: badge.title, tint: badge.tint)
      }
      text
        .lineLimit(1)
        .truncationMode(.middle)
    }
    .font(.subheadline)
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(checkout.summary)
  }

  private var text: Text {
    // The glyph is decorative: the line carries the summary as its label.
    // swiftlint:disable:next accessibility_label_for_image
    let glyph = Text(Image(systemName: "arrow.triangle.branch")).foregroundStyle(.secondary)
    let branch: Text
    if let name = checkout.branch {
      branch = Text(name).fontWeight(.medium)
    } else {
      branch = Text(checkout.branchPlaceholder ?? "").foregroundStyle(.secondary)
    }
    var line = Text("\(glyph) \(branch)")
    if let relation = checkout.relation {
      let word = Text("  \(relation.word) ").foregroundStyle(.secondary)
      line = Text("\(line)\(word)\(relation.ref)")
    }
    if let note = checkout.note {
      line = Text("\(line)\(Text(" · \(note)").foregroundStyle(.secondary))")
    }
    return line
  }
}

/// A small tinted capsule naming the kind of checkout.
struct WorkspaceCheckoutBadge: View {
  let title: String
  let tint: Color

  var body: some View {
    Text(title)
      .font(.caption2.weight(.semibold))
      .foregroundStyle(tint)
      .padding(.horizontal, 6)
      .padding(.vertical, 2)
      .background(tint.opacity(0.14), in: Capsule())
      .accessibilityHidden(true)
  }
}

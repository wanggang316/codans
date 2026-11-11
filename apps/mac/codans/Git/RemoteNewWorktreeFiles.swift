import CodansCore
import Foundation

/// A view, on a remote host, of the project files a new worktree will have,
/// for skill completion before the worktree exists (ADR 0010). The remote
/// counterpart of `NewWorktreeFiles`. A remote project creates a worktree
/// with plain `git worktree add <path> <ref>` and copies no ignored or
/// untracked files, so the view holds only the files the ref tracks under
/// the paths skill completion reads (`SkillLocationResolver.projectFilePaths`).
/// A relative symlink in the view whose target is elsewhere in the
/// repository gets that target too.
///
/// The view is a temporary directory on the host. The caller removes it
/// with `removeView`; a view left behind (a cancelled load) is removed by
/// the next `makeView` after an hour.
nonisolated struct RemoteNewWorktreeFiles: Sendable {
  /// Symlink targets are followed this many rounds; a deeper chain stays
  /// dangling, so its skill is not offered.
  static let maxSymlinkRounds = 8
  /// The name prefix of every view. `removeView` removes only such paths.
  static let viewPrefix = "codans-new-worktree."

  let reader: RemoteSkillReader

  /// The path of a new view on the host, or `nil` when git on the host
  /// cannot read `ref` (then no project file can be trusted). Throws when
  /// the host cannot be reached.
  func makeView(repoRoot: String, ref: String, paths: [String]) async throws(RemoteSkillReadError) -> String? {
    // git refuses a path outside the repository, and the new worktree's
    // place relative to such a path is unknown anyway.
    var pending = paths.compactMap(SkillLocationResolver.pathInside)
    var done = Set<String>()
    var view = ""
    for _ in 0...Self.maxSymlinkRounds {
      pending = pending.filter { done.insert($0).inserted }
      guard !pending.isEmpty || view.isEmpty else { break }
      let reply = try await reader.run(Self.script, arguments: [view, repoRoot, ref] + pending)
      guard let round = Self.parse(reply) else {
        if !view.isEmpty { await removeView(view) }
        throw RemoteSkillReadError(reason: "\(reader.host.authority) sent a reply codans cannot read")
      }
      guard let path = round.view else {
        if !view.isEmpty { await removeView(view) }
        return nil
      }
      view = path
      pending = round.danglingTargets
    }
    return view
  }

  /// Removes `view` from the host. A failure leaves it for the next
  /// `makeView` to remove.
  func removeView(_ view: String) async {
    _ = try? await reader.run(Self.removeScript, arguments: [view])
  }

  // MARK: - Scripts

  /// POSIX `sh`. `$1` is the view (empty: make one), `$2` the repository
  /// root, `$3` the ref, then the paths to add. Records after the marker:
  /// `v` the view path, or `g` when git cannot read the ref; then per
  /// symlink in the view `l` (its path in the view), `t` (its target), and
  /// `e` or `n` (the target exists or not).
  static let script = RemoteSkillReader.prelude + scriptBody

  private static let scriptBody = #"""
    view=$1; root=$2; ref=$3; shift 3
    if ! git -C "$root" rev-parse --verify -q "$ref^{commit}" >/dev/null 2>&1; then none g 0; exit 0; fi
    if [ -z "$view" ]; then
      base=${TMPDIR:-/tmp}; base=${base%/}
      find "$base" -maxdepth 1 -name 'codans-new-worktree.*' -mmin +60 \
        -exec rm -rf {} + 2>/dev/null
      view=$(mktemp -d "$base/codans-new-worktree.XXXXXX") || { none g 0; exit 0; }
    fi
    # Check the files out of the ref through a private index, as
    # `git worktree add` does: `git archive` would apply export-ignore.
    # The view is the work tree, so attributes come from the ref, not from
    # a .gitattributes only the main checkout has.
    index=$view.index
    fail() { rm -rf -- "$view" "$index"; none g 0; exit 0; }
    if [ ! -f "$index" ]; then
      GIT_INDEX_FILE=$index git -C "$root" read-tree "$ref" 2>/dev/null || fail
    fi
    if [ "$#" -gt 0 ]; then
      GIT_INDEX_FILE=$index git -C "$root" --literal-pathspecs ls-files -z -- "$@" \
        | GIT_INDEX_FILE=$index git -C "$root" --work-tree="$view" checkout-index -f -z --stdin || fail
    fi
    str v 0 "$view"
    find "$view" -type l | while IFS= read -r link; do
      str l 0 "${link#"$view"/}"
      str t 0 "$(readlink "$link")"
      if [ -e "$link" ]; then none e 0; else none n 0; fi
    done
    """#

  /// Removes `$1` only when it is a view, so a wrong argument never
  /// removes anything else.
  static let removeScript = #"""
    case "${1##*/}" in
      codans-new-worktree.*) rm -rf -- "$1" "$1.index" ;;
    esac
    """#

  struct Round: Equatable {
    /// `nil` when git on the host could not read the ref.
    var view: String?
    /// Paths in the view that a relative symlink points to and that are
    /// missing.
    var danglingTargets: [String]
  }

  /// `nil` when the reply cannot be read.
  static func parse(_ reply: Data) -> Round? {
    guard let records = RemoteSkillReader.records(in: reply) else { return nil }
    var round = Round(view: nil, danglingTargets: [])
    var link: String?
    var target: String?
    for record in records {
      let text = String(data: record.bytes, encoding: .utf8)
      switch record.kind {
      case "g": return Round(view: nil, danglingTargets: [])
      case "v": round.view = text
      case "l": link = text
      case "t": target = text
      case "e", "n":
        if record.kind == "n", let link, let target, let path = danglingTarget(link: link, target: target) {
          round.danglingTargets.append(path)
        }
        link = nil
        target = nil
      default: return nil
      }
    }
    return round.view?.hasPrefix("/") == true ? round : nil
  }

  /// The view path that the relative symlink at `link` points to, or `nil`
  /// for an absolute target or one outside the view: from the new worktree
  /// those point to the host's own files or outside the repository.
  static func danglingTarget(link: String, target: String) -> String? {
    guard !target.hasPrefix("/") else { return nil }
    return SkillLocationResolver.pathInside(
      (link.split(separator: "/").dropLast() + [Substring(target)]).joined(separator: "/"))
  }
}

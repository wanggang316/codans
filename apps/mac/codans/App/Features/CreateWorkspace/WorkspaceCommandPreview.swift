import CodansCore
import Foundation

/// What creating a plan will put on disk and which git commands do it,
/// rendered for the sheet's preview so the user sees the outcome before
/// pressing Create. Pure; mirrors the client's order of operations.
nonisolated enum WorkspaceCommandPreview {
  /// The folder tree: root, then one line per member with its branch.
  static func treeLines(for plan: WorkspacePlan) -> [String] {
    let root = (plan.rootPath as NSString).abbreviatingWithTildeInPath
    let rootName = (root as NSString).lastPathComponent
    var lines = ["\(rootName.isEmpty ? root : rootName)/"]
    for (index, member) in plan.members.enumerated() {
      let connector = index == plan.members.count - 1 ? "└─" : "├─"
      lines.append("\(connector) \(member.name)/  (\(member.checkout.branch))")
    }
    return lines
  }

  /// The commands, in the order the client runs them. Values the client
  /// fills in at run time (a default base ref) are shown as placeholders.
  static func commands(for plan: WorkspacePlan) -> [String] {
    var lines = ["mkdir -p \(quote(plan.rootPath))"]
    for member in plan.members {
      let destination = (plan.rootPath as NSString).appendingPathComponent(member.name)
      if case .remote(let url, let cloneDestination) = member.source {
        lines.append("git clone --progress \(quote(url)) \(quote(cloneDestination))")
      }
      lines.append(worktreeAddCommand(member: member, destination: destination))
    }
    lines.append(
      "write \(quote((plan.rootPath as NSString).appendingPathComponent(WorkspaceLayout.rootRelativeManifestPath)))")
    return lines
  }

  static func worktreeAddCommand(member: WorkspacePlan.Member, destination: String) -> String {
    let source = quote(member.sourceGitRoot)
    switch member.checkout {
    case .newBranch(let branch, let baseRef):
      let base = baseRef ?? "<default branch>"
      return "git -C \(source) worktree add -b \(quote(branch)) \(quote(destination)) \(quote(base))"
    case .existingBranch(let branch):
      return "git -C \(source) worktree add \(quote(destination)) \(quote(branch))"
    case .remoteTrackingRef(let remoteRef, let branch, let resetLocal):
      let flag = resetLocal ? "-B" : "-b"
      return "git -C \(source) worktree add --track \(flag) \(quote(branch)) \(quote(destination)) \(quote(remoteRef))"
    }
  }

  /// Shell-safe when the value has anything a shell would split on.
  private static func quote(_ value: String) -> String {
    let safe = value.allSatisfy { $0.isLetter || $0.isNumber || "/-_.:@~+=".contains($0) }
    if safe, !value.isEmpty { return value }
    return "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
  }
}

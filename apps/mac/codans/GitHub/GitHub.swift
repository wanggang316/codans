import Foundation

/// Namespace for the in-app GitHub integration module.
///
/// The module wraps the `gh` CLI to surface PR-centric information (status, checks,
/// merge / close actions) for each Worktree.
///
/// Dependency rules (folder-level, enforced by review):
/// - May import `Foundation`, `CodansCore`, and `codans/Process/` (`CommandRunner`).
/// - Must not import `codans/Git/`, `codans/Runtime/`, `codans/Hooks/`, SwiftUI,
///   or TCA. The app-layer TCA wrapper lives in `App/Clients/GitHubClient.swift` and
///   `App/Features/GitHub/`.
public enum GitHub {}

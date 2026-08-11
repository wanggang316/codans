import Foundation

/// Result of the one-shot `git --version` probe. Distinguishes an **environment-level**
/// block — one that makes every `git` invocation on the machine fail — from the per-repository
/// failures `GitError` already models.
///
/// The distinction matters because the two demand opposite presentations. A per-repository
/// failure belongs on that repository's row (`ProjectLoadState.failed`). An environment block
/// is not the repository's fault: marking each Project failed would tell a user with ten
/// healthy checkouts that all ten are broken, when one `sudo xcodebuild -license accept`
/// fixes the lot. The latter gets a single actionable banner instead.
nonisolated enum GitEnvironmentStatus: Equatable, Sendable {
  /// `git --version` exited 0. Payload is the trimmed version line, for diagnostics.
  case ok(version: String)
  /// `git` is present but unusable, or absent entirely.
  case blocked(GitEnvironmentBlock)

  var block: GitEnvironmentBlock? {
    guard case .blocked(let block) = self else { return nil }
    return block
  }
}

/// Why `git` is unusable machine-wide, with the copy the banner renders.
///
/// Classification is deliberately coarse: the goal is to hand the user the one command that
/// unblocks them, not to enumerate every failure mode. Anything unrecognised falls into
/// `.unknown` and echoes git's own stderr rather than guessing at a remedy.
nonisolated enum GitEnvironmentBlock: Equatable, Sendable {
  /// Exit 69. Git is installed, but the Xcode / Command Line Tools license has never been
  /// accepted on this machine — the single most common state on a fresh or newly-migrated Mac.
  case xcodeLicenseNotAccepted
  /// The `/usr/bin/git` shim resolved, but the Command Line Tools it forwards to are missing
  /// or point at a stale developer directory (typical after a major macOS upgrade).
  case developerToolsMissing
  /// No executable at `/usr/bin/git` at all — the spawn itself failed.
  case gitNotFound
  /// Non-zero exit we have no specific remedy for. Carries git's first stderr line verbatim.
  case unknown(detail: String)

  /// Short banner headline.
  var title: String {
    switch self {
    case .xcodeLicenseNotAccepted: "Xcode license not accepted"
    case .developerToolsMissing: "Command Line Tools not installed"
    case .gitNotFound: "git not found"
    case .unknown: "git is not usable"
    }
  }

  /// One-sentence explanation, phrased around the consequence the user is actually seeing
  /// (empty projects) rather than around the mechanism.
  var explanation: String {
    switch self {
    case .xcodeLicenseNotAccepted:
      "git is installed but refuses to run until the Xcode license is accepted. "
        + "Until then every project here will look empty."
    case .developerToolsMissing:
      "macOS ships a git stub that forwards to the Xcode Command Line Tools, "
        + "which aren't installed on this machine. Until they are, every project here will look empty."
    case .gitNotFound:
      "No git executable was found at /usr/bin/git, so no repository can be read."
    case .unknown(let detail):
      detail
    }
  }

  /// Shell command that resolves the block, offered with a Copy button. `nil` when we have no
  /// remedy to suggest — better to show none than to send the user at a command that won't help.
  var remedyCommand: String? {
    switch self {
    case .xcodeLicenseNotAccepted: "sudo xcodebuild -license accept"
    case .developerToolsMissing, .gitNotFound: "xcode-select --install"
    case .unknown: nil
    }
  }
}

extension GitEnvironmentStatus {
  /// Maps a `git --version` outcome onto a status.
  ///
  /// Pure and total, so the whole classification table is unit-testable without spawning a
  /// process. Matching is case-insensitive over stderr; the probe pins the child's locale via
  /// `GitProcessEnv` (`LC_ALL=C.UTF-8`), which is what makes matching English substrings a
  /// sound strategy rather than a guess about the user's system language.
  ///
  /// Explicitly `nonisolated`: the app target defaults to `@MainActor`, and unlike members
  /// declared inside a `nonisolated` type's own body, an extension's members pick up that
  /// default. The probe calls this from an actor, off the main thread.
  nonisolated static func classify(_ outcome: CommandOutcome) -> GitEnvironmentStatus {
    switch outcome {
    case .spawnFailed:
      return .blocked(.gitNotFound)

    case .timedOut:
      return .blocked(.unknown(detail: "git --version did not respond within 5 seconds."))

    case .exited(let code, let stdout, let stderr, _):
      guard code != 0 else {
        let version =
          String(data: stdout, encoding: .utf8)?
          .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return .ok(version: version)
      }
      let text = String(data: stderr, encoding: .utf8) ?? ""
      let haystack = text.lowercased()

      // Exit 69 (EX_UNAVAILABLE) is what the license gate returns, but match on the message
      // too: the same text is emitted with other codes depending on the shim's version.
      if haystack.contains("xcodebuild -license")
        || haystack.contains("agreeing to the xcode")
        || haystack.contains("license agreement")
      {
        return .blocked(.xcodeLicenseNotAccepted)
      }
      if haystack.contains("no developer tools were found")
        || haystack.contains("invalid active developer path")
        || haystack.contains("unable to find utility")
        || haystack.contains("command line tools")
      {
        return .blocked(.developerToolsMissing)
      }

      let firstLine =
        text
        .split(separator: "\n", omittingEmptySubsequences: true)
        .first
        .map { $0.trimmingCharacters(in: .whitespaces) }
        .flatMap { $0.isEmpty ? nil : $0 }
      return .blocked(.unknown(detail: firstLine ?? "git --version exited with code \(code)."))
    }
  }
}

import Foundation
import Testing
import TouchCodeCore

@testable import TouchCode

struct GitServiceClientBranchTests {
  /// `live(service:)` must forward the new closures to the underlying service
  /// 1:1, in argument order. Recorded calls double as a regression guard against
  /// the `switchBranch` / `renameCurrentBranch` arguments being flipped during
  /// refactors.
  @Test
  func liveForwardsNewClosuresToUnderlyingService() async throws {
    let fake = FakeGitService()
    let client = GitServiceClient.live(service: fake)
    let url = URL(fileURLWithPath: "/tmp/x")

    _ = try await client.currentBranch(url)
    _ = try await client.listAllBranches(url)
    try await client.switchBranch(.local(name: "main"), url)
    try await client.switchBranch(.remoteTracking(shortName: "origin/x"), url)
    try await client.renameCurrentBranch("feat/renamed", url)

    let calls = fake.recordedCalls()
    #expect(
      calls == [
        .currentBranch(url),
        .listAllBranches(url),
        .switchBranch(.local(name: "main"), url),
        .switchBranch(.remoteTracking(shortName: "origin/x"), url),
        .renameCurrentBranch("feat/renamed", url),
      ])
  }

  /// `testValue` must declare the new closures so feature tests that override
  /// them with `withDependencies` see populated stored properties (the missing-key
  /// case would surface as a nil-closure trap at call site). This is a compile-time
  /// witness — `unimplemented(...)` itself is verified at runtime by feature tests
  /// that exercise the closures without overrides.
  @Test
  func testValueDeclaresNewClosures() {
    let client = GitServiceClient.testValue
    _ = client.currentBranch
    _ = client.listAllBranches
    _ = client.switchBranch
    _ = client.renameCurrentBranch
  }
}

// swiftlint:disable async_without_await
// Minimum protocol surface for the forwarding test. Lock-based bookkeeping rather
// than an `actor` because `GitService` is a `nonisolated` protocol — actor
// isolation would reject the conformance. The protocol methods are `async` but
// the test fake's bodies are synchronous; mirrors the pattern used by other
// mock implementations in this target (see `MockOSNotifier`).
private final class FakeGitService: GitService, @unchecked Sendable {
  enum Call: Equatable {
    case currentBranch(URL)
    case listAllBranches(URL)
    case switchBranch(BranchSwitchTarget, URL)
    case renameCurrentBranch(String, URL)
  }

  private let lock = NSLock()
  private var calls: [Call] = []

  func recordedCalls() -> [Call] {
    lock.lock()
    defer { lock.unlock() }
    return calls
  }

  private func record(_ call: Call) {
    lock.lock()
    defer { lock.unlock() }
    calls.append(call)
  }

  func currentBranch(at path: URL) async throws -> String? {
    record(.currentBranch(path))
    return "main"
  }

  func listAllBranches(at path: URL) async throws -> BranchInventory {
    record(.listAllBranches(path))
    return BranchInventory(current: "main", local: [], remote: [])
  }

  func switchBranch(to target: BranchSwitchTarget, at path: URL) async throws {
    record(.switchBranch(target, path))
  }

  func renameCurrentBranch(to newName: String, at path: URL) async throws {
    record(.renameCurrentBranch(newName, path))
  }

  // === Unused protocol surface — trap if accidentally called. ===
  func log(at path: URL, page: LogPage.Cursor) async throws -> LogPage { fatalError() }
  func workingTreeDiff(at path: URL, ignoreWhitespace: Bool) async throws -> UnifiedDiff {
    fatalError()
  }
  func stagedDiff(at path: URL, ignoreWhitespace: Bool) async throws -> UnifiedDiff {
    fatalError()
  }
  func commitDiff(at path: URL, sha: String, ignoreWhitespace: Bool) async throws -> UnifiedDiff {
    fatalError()
  }
  func status(at path: URL) async throws -> WorkingTreeStatus { fatalError() }
  func remoteInfo(at path: URL) async throws -> RemoteInfo { fatalError() }
  func diffNumstat(at worktreePath: URL) async throws -> [ChangedFile] { fatalError() }
  func showFileAtHEAD(_ path: String, at worktreePath: URL) async throws -> String? {
    fatalError()
  }
  func localDiffStats(at worktreePath: URL) async throws -> LocalDiffStats? { fatalError() }
}
// swiftlint:enable async_without_await

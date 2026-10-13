import Foundation
import Testing

@testable import Codans

struct WorkflowPathWatchTests {
  private static func temporaryDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(
      "workflow-watch-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
  }

  /// A file written into the watched directory fires the callback, and
  /// dropping the watch runs its cancel handlers on the dispatch queue —
  /// which trapped while the class inherited the app's main-actor default.
  @Test
  func aWriteFiresAndDroppingTheWatchCancelsCleanly() async throws {
    let directory = try Self.temporaryDirectory()
    let fired = AsyncStream<Void>.makeStream()
    var watch: WorkflowPathWatch? = WorkflowPathWatch(
      directory: directory, stopAt: nil, files: [], onChange: { fired.continuation.yield() })
    try Data("name: x\n".utf8).write(to: directory.appendingPathComponent("x.workflow.yaml"))

    var iterator = fired.stream.makeAsyncIterator()
    let didFire: Void? = await iterator.next()
    #expect(didFire != nil)

    watch = nil
    _ = watch
    try await Task.sleep(for: .milliseconds(100))
  }

  /// Until the workflows directory exists, the nearest existing ancestor
  /// (bounded by the worktree root) is watched, so its creation is seen.
  @Test
  func aMissingDirectoryIsWatchedThroughItsAncestor() async throws {
    let root = try Self.temporaryDirectory()
    let directory = root.appendingPathComponent(".codans/workflows", isDirectory: true)
    let fired = AsyncStream<Void>.makeStream()
    let watch = WorkflowPathWatch(
      directory: directory, stopAt: root, files: [], onChange: { fired.continuation.yield() })
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

    var iterator = fired.stream.makeAsyncIterator()
    let didFire: Void? = await iterator.next()
    #expect(didFire != nil)
    _ = watch
  }
}

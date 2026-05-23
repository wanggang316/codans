import ComposableArchitecture
import Foundation
import Testing
import TouchCodeCore

@testable import touch_code

/// Each control in the General pane fans out through
/// `ProjectGeneralSettingsView.WriteRoutes`. These tests construct a
/// `WriteRoutes` with a `SettingsWriter` whose closures record the
/// (projectID, payload) pairs they receive, then exercise each route and
/// assert the right closure fired with the right arguments.
@MainActor
struct ProjectGeneralSettingsViewWriteRoutingTests {
  // MARK: - Editor

  @Test
  func writeDefaultEditorRoutesToSetProjectDefaultEditor() async {
    let captured = LockIsolated<[(ProjectID, EditorID?)]>([])
    let pid = ProjectID()
    var writer = SettingsWriter.testValue
    writer.setProjectDefaultEditor = { pid, value in
      captured.withValue { $0.append((pid, value)) }
    }

    let routes = ProjectGeneralSettingsView.WriteRoutes(projectID: pid, writer: writer)
    routes.writeDefaultEditor("vscode")
    await waitForCapture(captured)

    #expect(captured.value.count == 1)
    #expect(captured.value.first?.0 == pid)
    #expect(captured.value.first?.1 == "vscode")
  }

  // MARK: - Worktree fields

  @Test
  func writeWorktreeBaseRefTrimsAndRoutesAsGitFieldUpdate() async {
    let captured = LockIsolated<[SettingsWriter.GitFieldUpdate]>([])
    let pid = ProjectID()
    var writer = SettingsWriter.testValue
    writer.setProjectGitField = { _, update in
      captured.withValue { $0.append(update) }
    }

    let routes = ProjectGeneralSettingsView.WriteRoutes(projectID: pid, writer: writer)
    routes.writeWorktreeBaseRef("  origin/main  ")
    await waitForCapture(captured)

    #expect(captured.value == [.worktreeBaseRef("origin/main")])
  }

  @Test
  func writeWorktreeBaseRefEmptyValueWritesNilToClearOverride() async {
    let captured = LockIsolated<[SettingsWriter.GitFieldUpdate]>([])
    let pid = ProjectID()
    var writer = SettingsWriter.testValue
    writer.setProjectGitField = { _, update in
      captured.withValue { $0.append(update) }
    }

    let routes = ProjectGeneralSettingsView.WriteRoutes(projectID: pid, writer: writer)
    routes.writeWorktreeBaseRef("   ")
    await waitForCapture(captured)

    #expect(captured.value == [.worktreeBaseRef(nil)])
  }

  @Test
  func writeCopyToggleRoutesPreserveTriStateNilTrueFalse() async {
    let captured = LockIsolated<[SettingsWriter.GitFieldUpdate]>([])
    let pid = ProjectID()
    var writer = SettingsWriter.testValue
    writer.setProjectGitField = { _, update in
      captured.withValue { $0.append(update) }
    }

    let routes = ProjectGeneralSettingsView.WriteRoutes(projectID: pid, writer: writer)
    routes.writeCopyIgnored(true)
    routes.writeCopyIgnored(nil)
    routes.writeCopyUntracked(false)
    // Each route spawns a detached Task so ordering is racy; assert as
    // multiset membership instead of positional equality.
    await waitForCount(captured, expected: 3)

    #expect(captured.value.count == 3)
    #expect(captured.value.contains(.copyIgnoredOnWorktreeCreate(true)))
    #expect(captured.value.contains(.copyIgnoredOnWorktreeCreate(nil)))
    #expect(captured.value.contains(.copyUntrackedOnWorktreeCreate(false)))
  }

  // MARK: - GitHub fields

  @Test
  func writeMergeStrategyAndPostMergeActionRoute() async {
    let captured = LockIsolated<[SettingsWriter.GitFieldUpdate]>([])
    let pid = ProjectID()
    var writer = SettingsWriter.testValue
    writer.setProjectGitField = { _, update in
      captured.withValue { $0.append(update) }
    }

    let routes = ProjectGeneralSettingsView.WriteRoutes(projectID: pid, writer: writer)
    routes.writeMergeStrategy(.squash)
    routes.writePostMergeAction(.archive)
    routes.writeGithubDisabled(true)
    await waitForCount(captured, expected: 3)

    #expect(captured.value.count == 3)
    #expect(captured.value.contains(.defaultMergeStrategy(.squash)))
    #expect(captured.value.contains(.postMergeAction(.archive)))
    #expect(captured.value.contains(.githubDisabled(true)))
  }

  // MARK: - Environment

  @Test
  func writeEnvVarRoutesUpsertAndDelete() async {
    let captured = LockIsolated<[(ProjectID, String, String?)]>([])
    let pid = ProjectID()
    var writer = SettingsWriter.testValue
    writer.setProjectEnvVar = { pid, key, value in
      captured.withValue { $0.append((pid, key, value)) }
    }

    let routes = ProjectGeneralSettingsView.WriteRoutes(projectID: pid, writer: writer)
    routes.writeEnvVar(key: "FOO", value: "bar")
    routes.writeEnvVar(key: "FOO", value: nil)
    await waitForCount(captured, expected: 2)

    #expect(captured.value.count == 2)
    let snapshot = captured.value
    let upsert = snapshot.contains { $0.1 == "FOO" && $0.2 == "bar" }
    let delete = snapshot.contains { $0.1 == "FOO" && $0.2 == nil }
    #expect(upsert)
    #expect(delete)
  }

  // MARK: - Helpers

  /// Each route spawns a detached `Task { await … }` to invoke the writer.
  /// Polling keeps the tests free of arbitrary `try? await Task.sleep` and
  /// terminates as soon as the captured count is non-empty.
  private func waitForCapture<T: Sendable>(_ box: LockIsolated<[T]>) async {
    await waitForCount(box, expected: 1)
  }

  private func waitForCount<T: Sendable>(_ box: LockIsolated<[T]>, expected: Int) async {
    let deadline = Date().addingTimeInterval(2.0)
    while box.value.count < expected {
      if Date() > deadline { break }
      await Task.yield()
      try? await Task.sleep(nanoseconds: 1_000_000)
    }
  }
}

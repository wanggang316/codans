import Foundation
import Testing
import TouchCodeCore

@testable import touch_code

/// Coverage for the `SettingsWriter` closures introduced in Phase 2.
/// Each test uses a real `SettingsStore` backed by a temp file so we exercise
/// the `mutateProject` path and verify persistence end-to-end.
@MainActor
struct SettingsWriterPhase2Tests {
  private func makeStore() -> (SettingsStore, URL) {
    let url = FileManager.default.temporaryDirectory.appending(
      component: "settings-writer-phase2-\(UUID().uuidString).json"
    )
    return (SettingsStore(fileURL: url), url)
  }

  // MARK: - setProjectGitField

  @Test
  func setProjectGitFieldGithubDisabledRoundTripsThroughCollapse() async throws {
    let (store, url) = makeStore()
    defer { try? FileManager.default.removeItem(at: url) }
    let writer = SettingsWriter.live(store)
    let pid = ProjectID()

    await writer.setProjectGitField(pid, .githubDisabled(true))
    #expect(store.settings.projects[pid]?.git?.githubDisabled == true)

    // Flipping back to false makes the git subtree effectively empty;
    // collapseEmptyGit drops it.
    await writer.setProjectGitField(pid, .githubDisabled(false))
    #expect(store.settings.projects[pid]?.git == nil)
  }

  @Test
  func setProjectGitFieldMergeStrategyAndPostMergeAction() async throws {
    let (store, url) = makeStore()
    defer { try? FileManager.default.removeItem(at: url) }
    let writer = SettingsWriter.live(store)
    let pid = ProjectID()

    await writer.setProjectGitField(pid, .defaultMergeStrategy(.squash))
    await writer.setProjectGitField(pid, .postMergeAction(.archive))
    #expect(store.settings.projects[pid]?.git?.defaultMergeStrategy == .squash)
    #expect(store.settings.projects[pid]?.git?.postMergeAction == .archive)
  }

  @Test
  func setProjectGitFieldWorktreeBaseRefAndCopyToggles() async throws {
    let (store, url) = makeStore()
    defer { try? FileManager.default.removeItem(at: url) }
    let writer = SettingsWriter.live(store)
    let pid = ProjectID()

    await writer.setProjectGitField(pid, .worktreeBaseRef("origin/main"))
    await writer.setProjectGitField(pid, .copyIgnoredOnWorktreeCreate(true))
    await writer.setProjectGitField(pid, .copyUntrackedOnWorktreeCreate(false))

    #expect(store.settings.projects[pid]?.git?.worktreeBaseRef == "origin/main")
    #expect(store.settings.projects[pid]?.git?.copyIgnoredOnWorktreeCreate == true)
    #expect(store.settings.projects[pid]?.git?.copyUntrackedOnWorktreeCreate == false)
  }

  // MARK: - setProjectEnvVar

  @Test
  func setProjectEnvVarUpsertsAndRemoves() async throws {
    let (store, url) = makeStore()
    defer { try? FileManager.default.removeItem(at: url) }
    let writer = SettingsWriter.live(store)
    let pid = ProjectID()

    await writer.setProjectEnvVar(pid, "FOO", "bar")
    #expect(store.settings.projects[pid]?.envVars["FOO"] == "bar")

    await writer.setProjectEnvVar(pid, "FOO", "baz")
    #expect(store.settings.projects[pid]?.envVars["FOO"] == "baz")

    await writer.setProjectEnvVar(pid, "FOO", nil)
    #expect(store.settings.projects[pid]?.envVars["FOO"] == nil)
  }

  // MARK: - setProjectScripts

  @Test
  func setProjectScriptsReplacesArray() async throws {
    let (store, url) = makeStore()
    defer { try? FileManager.default.removeItem(at: url) }
    let writer = SettingsWriter.live(store)
    let pid = ProjectID()

    let initial = [
      ScriptDefinition(kind: .run, name: "Dev", command: "npm run dev"),
      ScriptDefinition(kind: .test, name: "Test", command: "npm test"),
    ]
    await writer.setProjectScripts(pid, initial)
    #expect(store.settings.projects[pid]?.scripts.count == 2)
    #expect(store.settings.projects[pid]?.scripts[0].name == "Dev")

    await writer.setProjectScripts(pid, [])
    #expect(store.settings.projects[pid]?.scripts.isEmpty == true)
  }

  // MARK: - setProjectLifecycleScript

  @Test
  func setProjectLifecycleScriptWritesEachPhase() async throws {
    let (store, url) = makeStore()
    defer { try? FileManager.default.removeItem(at: url) }
    let writer = SettingsWriter.live(store)
    let pid = ProjectID()

    await writer.setProjectLifecycleScript(pid, .setup, "npm install")
    await writer.setProjectLifecycleScript(pid, .archive, "git lfs prune")
    await writer.setProjectLifecycleScript(pid, .delete, "echo gone")

    #expect(store.settings.projects[pid]?.git?.createScript?.command == "npm install")
    #expect(store.settings.projects[pid]?.git?.archiveScript?.command == "git lfs prune")
    #expect(store.settings.projects[pid]?.git?.deleteScript?.command == "echo gone")
  }

  @Test
  func setProjectLifecycleScriptEmptyClearsAndCollapsesGit() async throws {
    let (store, url) = makeStore()
    defer { try? FileManager.default.removeItem(at: url) }
    let writer = SettingsWriter.live(store)
    let pid = ProjectID()

    await writer.setProjectLifecycleScript(pid, .setup, "npm install")
    #expect(store.settings.projects[pid]?.git?.createScript?.command == "npm install")

    await writer.setProjectLifecycleScript(pid, .setup, "")
    // Setup was the only field set; an empty git subtree collapses to nil.
    #expect(store.settings.projects[pid]?.git == nil)
  }

  // MARK: - persistence

  @Test
  func phase2WritesPersistThroughFlushAndReload() async throws {
    let url = FileManager.default.temporaryDirectory.appending(
      component: "settings-writer-phase2-persist-\(UUID().uuidString).json"
    )
    defer { try? FileManager.default.removeItem(at: url) }
    let pid = ProjectID()

    do {
      let store = SettingsStore(fileURL: url)
      let writer = SettingsWriter.live(store)
      await writer.setProjectEnvVar(pid, "MY_VAR", "hello")
      await writer.setProjectScripts(
        pid,
        [
          ScriptDefinition(kind: .test, name: "Test", command: "go test ./...")
        ])
      await writer.setProjectGitField(pid, .githubDisabled(true))
      await writer.setProjectLifecycleScript(pid, .setup, "echo SETUP")
      store.flush()
    }

    let reloaded = SettingsStore(fileURL: url)
    #expect(reloaded.settings.projects[pid]?.envVars["MY_VAR"] == "hello")
    #expect(reloaded.settings.projects[pid]?.scripts.count == 1)
    #expect(reloaded.settings.projects[pid]?.git?.githubDisabled == true)
    #expect(reloaded.settings.projects[pid]?.git?.createScript?.command == "echo SETUP")
  }
}

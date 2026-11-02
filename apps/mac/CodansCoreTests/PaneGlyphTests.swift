import Foundation
import Testing

@testable import CodansCore

/// One glyph rule for a pane card header and the tab chip that shows the
/// same pane.
struct PaneGlyphTests {
  private let script = ScriptDefinition(
    kind: .run, name: "Build", command: "make", systemImage: "hammer.fill", tintColor: .teal)

  private var settings: Settings {
    var settings = Settings()
    settings.general.globalScripts = [script]
    return settings
  }

  @Test
  func plainPaneShowsTerminal() {
    let glyph = PaneGlyph.resolve(pane: Pane(workingDirectory: "/tmp"), settings: settings, isBusy: true)
    #expect(glyph == PaneGlyph(icon: PaneGlyph.terminalIcon, tint: nil))
  }

  @Test
  func missingPaneShowsTerminal() {
    let glyph = PaneGlyph.resolve(pane: nil, settings: settings, isBusy: false)
    #expect(glyph == PaneGlyph(icon: PaneGlyph.terminalIcon, tint: nil))
  }

  @Test
  func agentPaneShowsAgentMark() {
    let pane = Pane(workingDirectory: "/tmp", agentKind: .codex)
    let glyph = PaneGlyph.resolve(pane: pane, settings: settings, isBusy: true)
    #expect(glyph == PaneGlyph(icon: TabIconRef.icon(for: .codex), tint: nil))
  }

  @Test
  func idleRunScriptPaneShowsScriptIconUntinted() {
    let pane = Pane(workingDirectory: "/tmp", runScriptID: script.id)
    let glyph = PaneGlyph.resolve(pane: pane, settings: settings, isBusy: false)
    #expect(glyph == PaneGlyph(icon: "hammer.fill", tint: nil))
  }

  @Test
  func busyRunScriptPaneTakesScriptTint() {
    let pane = Pane(workingDirectory: "/tmp", runScriptID: script.id)
    let glyph = PaneGlyph.resolve(pane: pane, settings: settings, isBusy: true)
    #expect(glyph == PaneGlyph(icon: "hammer.fill", tint: .teal))
  }

  @Test
  func projectScriptIsFound() {
    var settings = Settings()
    let projectID = ProjectID()
    settings.projects[projectID] = ProjectSettings(scripts: [script])
    let pane = Pane(workingDirectory: "/tmp", runScriptID: script.id)
    let glyph = PaneGlyph.resolve(pane: pane, settings: settings, isBusy: false)
    #expect(glyph.icon == "hammer.fill")
  }

  @Test
  func agentInRunScriptPaneShowsAgentMark() {
    let pane = Pane(workingDirectory: "/tmp", agentKind: .claudeCode, runScriptID: script.id)
    let glyph = PaneGlyph.resolve(pane: pane, settings: settings, isBusy: true)
    #expect(glyph == PaneGlyph(icon: TabIconRef.icon(for: .claudeCode), tint: nil))
  }

  @Test
  func runPaneOfDeletedScriptShowsTerminal() {
    let pane = Pane(workingDirectory: "/tmp", runScriptID: UUID())
    let glyph = PaneGlyph.resolve(pane: pane, settings: settings, isBusy: true)
    #expect(glyph == PaneGlyph(icon: PaneGlyph.terminalIcon, tint: nil))
  }
}

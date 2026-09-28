import AppKit
import Testing

@testable import Codans

@MainActor
struct RunMenuRowViewTests {
  private final class Calls {
    var runs = 0
    var adds = 0
  }

  private func makeRow(accessory: RunMenuRowView.Accessory?, calls: Calls) -> RunMenuRowView {
    let row = RunMenuRowView(
      content: .init(icon: nil, title: "lint", subtitle: "pnpm run lint", accessory: accessory),
      height: RunMenuMetrics.entryRowHeight
    )
    row.frame.size.width = 320
    row.onRun = { calls.runs += 1 }
    row.onAdd = { calls.adds += 1 }
    return row
  }

  private func mouseUp(in row: RunMenuRowView, at point: NSPoint) {
    let event = NSEvent.mouseEvent(
      with: .leftMouseUp, location: point, modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil,
      eventNumber: 0, clickCount: 1, pressure: 0)!
    row.mouseUp(with: event)
  }

  /// Actions are dispatched after the menu closes (next main-queue turn).
  private func drainMain() async {
    await withCheckedContinuation { continuation in
      DispatchQueue.main.async { continuation.resume() }
    }
  }

  // A detached row's window coordinates are its own, unflipped: y counts up
  // from the bottom, x from the leading edge.
  private func trailingAccessoryPoint(_ row: RunMenuRowView) -> NSPoint {
    NSPoint(x: row.bounds.maxX - 24, y: row.bounds.midY)
  }

  @Test
  func clickingTheRowRunsAndTheAccessoryAdds() async {
    let calls = Calls()
    let row = makeRow(accessory: .add, calls: calls)
    mouseUp(in: row, at: NSPoint(x: 60, y: row.bounds.midY))
    await drainMain()
    #expect((calls.runs, calls.adds) == (1, 0))

    mouseUp(in: row, at: trailingAccessoryPoint(row))
    await drainMain()
    #expect((calls.runs, calls.adds) == (1, 1))
  }

  /// Adding stays inside the open menu: the handler runs at once (no close
  /// first) and the accessory becomes the added mark, so a second click on
  /// it no longer adds.
  @Test
  func addingFlipsTheAccessoryToAddedInPlace() async {
    let calls = Calls()
    let row = makeRow(accessory: .add, calls: calls)
    mouseUp(in: row, at: trailingAccessoryPoint(row))
    #expect(calls.adds == 1)
    #expect(row.content.accessory == .added)
    #expect(row.accessibilityCustomActions() == nil)

    mouseUp(in: row, at: trailingAccessoryPoint(row))
    await drainMain()
    #expect((calls.runs, calls.adds) == (1, 1))
  }

  @Test
  func anAddedRowsCheckmarkIsNotAnAddButton() async {
    let calls = Calls()
    let row = makeRow(accessory: .added, calls: calls)
    mouseUp(in: row, at: trailingAccessoryPoint(row))
    await drainMain()
    #expect((calls.runs, calls.adds) == (1, 0))
  }

  @Test
  func returnRunsAndAccessibilityExposesAddAsACustomAction() async {
    let calls = Calls()
    let row = makeRow(accessory: .add, calls: calls)
    let returnKey = NSEvent.keyEvent(
      with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil,
      characters: "\r", charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36)!
    row.keyDown(with: returnKey)
    #expect(row.accessibilityPerformPress())
    await drainMain()
    #expect(calls.runs == 2)

    let actions = row.accessibilityCustomActions() ?? []
    #expect(actions.map(\.name) == ["Add to Project Commands"])
    _ = actions.first?.handler?()
    await drainMain()
    #expect(calls.adds == 1)
    #expect(row.accessibilityLabel() == "lint, pnpm run lint")
  }
}

@MainActor
struct RunMenuBuilderRefreshTests {
  private func command(_ title: String) -> RunMenuModel.Command {
    RunMenuModel.Command(id: UUID(), title: title, icon: .symbol("play.fill"), tint: .systemGreen, chord: nil) {}
  }

  private var configFile: RunMenuModel.ConfigFile {
    RunMenuModel.ConfigFile(title: "package.json", icon: nil, entries: [])
  }

  @Test
  func refreshSwapsOnlyTheCommandBlock() {
    let menu = NSMenu()
    var model = RunMenuModel()
    model.configFiles = [configFile]
    RunMenuBuilder.populate(menu, with: model, delegate: nil)
    let fileItem = menu.items.first { $0.title == "package.json" }
    #expect(menu.items.first?.title == "Config Files")

    // The first added command brings the Project section (and its separator)
    // in above the untouched Config Files items.
    model.projectCommands = [command("dev")]
    RunMenuBuilder.refreshCommands(in: menu, with: model)
    #expect(menu.items.prefix(4).map(\.title) == ["Project", "dev", "", "Config Files"])
    #expect(menu.items.first { $0.title == "package.json" } === fileItem)

    model.projectCommands = [command("dev"), command("build")]
    RunMenuBuilder.refreshCommands(in: menu, with: model)
    #expect(menu.items.prefix(5).map(\.title) == ["Project", "dev", "build", "", "Config Files"])
    #expect(menu.items.filter { $0.title == "Project" }.count == 1)
  }
}

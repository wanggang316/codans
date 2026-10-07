// A small SwiftUI app with one control per sv-tool command, for
// sv_tool_test.sh. Each control writes its effect into a static text, so a
// test can prove the effect through AX instead of trusting a return code.

import AppKit
import SwiftUI

final class Model: ObservableObject {
  @Published var toggled = false
  @Published var taps = 0
  @Published var name = ""
  @Published var mode = "A"
  @Published var row: String?
  @Published var bumps = 0
  @Published var hoverPresses = 0
  @Published var split = "none"
}

struct FixtureView: View {
  @ObservedObject var model: Model
  @State private var hovering = false

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      Button("Toggle") { model.toggled.toggle() }
        .accessibilityIdentifier("fixture.toggle")
      Text("state: \(model.toggled ? "on" : "off")")
      // A tap gesture has no AXPress action: AX reports success for a press
      // and nothing happens. Only a physical click reaches it.
      Text("Tap target")
        .padding(8)
        .background(Color.gray.opacity(0.2))
        .onTapGesture { model.taps += 1 }
      Text("taps: \(model.taps)")
      TextField("Name", text: $model.name)
      Text("name: \(model.name)")
      Picker("Mode", selection: $model.mode) {
        Text("A").tag("A")
        Text("B").tag("B")
      }
      .pickerStyle(.menu)
      Text("mode: \(model.mode)")
      List(["Row 1", "Row 2"], id: \.self, selection: $model.row) { Text($0) }
        .frame(height: 70)
      Text("row: \(model.row ?? "none")")
      Text("bumps: \(model.bumps)")
      HStack {
        Button("Dup") {}
        Button("Dup") {}
      }
      // A split button: the chevron segment has no label.
      Menu("Split") {
        Button("Split item") { model.split = "item" }
      } primaryAction: {
        model.split = "primary"
      }
      .fixedSize()
      Text("split: \(model.split)")
      HStack {
        Text("Hover row")
        if hovering {
          Button("Hover action") { model.hoverPresses += 1 }
        }
      }
      .padding(8)
      .contentShape(Rectangle())
      .onHover { hovering = $0 }
      Text("hover presses: \(model.hoverPresses)")
    }
    .padding(16)
    .frame(width: 320)
  }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
  let model = Model()
  var windows: [NSWindow] = []

  func applicationDidFinishLaunching(_ notification: Notification) {
    let menu = NSMenu()
    let appItem = NSMenuItem()
    appItem.submenu = NSMenu(title: "SvFixture")
    menu.addItem(appItem)
    let fixtureItem = NSMenuItem()
    let fixtureMenu = NSMenu(title: "Fixture")
    fixtureMenu.addItem(NSMenuItem(title: "Bump", action: #selector(bump), keyEquivalent: ""))
    fixtureItem.submenu = fixtureMenu
    menu.addItem(fixtureItem)
    NSApp.mainMenu = menu

    let main = makeWindow(title: "Fixture Main", origin: NSPoint(x: 60, y: 120), content: FixtureView(model: model))
    let second = makeWindow(title: "Fixture Second", origin: NSPoint(x: 420, y: 120), content: Text("second").padding(40))
    windows = [main, second]
    // Order front without activating: the test checks that nothing steals focus.
    second.orderFront(nil)
    main.orderFront(nil)
  }

  @objc func bump() { model.bumps += 1 }

  func makeWindow<Content: View>(title: String, origin: NSPoint, content: Content) -> NSWindow {
    let window = NSWindow(
      contentRect: NSRect(origin: origin, size: NSSize(width: 320, height: 200)),
      styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
    window.title = title
    window.isReleasedWhenClosed = false
    window.contentView = NSHostingView(rootView: content)
    window.setContentSize(window.contentView!.fittingSize)
    return window
  }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()

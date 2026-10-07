// PID-scoped Accessibility, window, and input driver for self-verify-codans.
//
// Every command takes the target PID explicitly. Release, dev, and test
// instances share the process name "Codans", so names and window titles are
// never used to find the app. Semantic commands (everything except click and
// hover) never activate the app or move the cursor.
//
// An element is addressed by AX role plus an exact label. The label matches
// the title, description, value, placeholder, or identifier; "" matches an
// element with no label and "*" any label. `--within <label>` limits the
// search to the subtree of the first element with that label; `--near
// <label>` to the subtree of its parent (siblings, such as the segments of a
// split button); `--after <label>` takes the first match after that element
// in tree order (a switch after its row text).
//
//   preflight                          JSON readiness; exit 0 READY, 2 SKIPPED
//   front                              PID of the frontmost app
//   activate <pid>                     activate an app (give focus back after a test)
//   windows <pid> [title]              on-screen windows: "<id> <x> <y> <w> <h> <title>"
//   tree <pid> [--window T] [--depth N]  indented AX tree of the app's windows
//   find <pid> <role|any> <label> [scope]   matching elements, one per line
//   get <pid> <role> <label> [scope]        one element as JSON
//   wait <pid> <role> <label> [scope] [--gone] [--timeout MS]
//   press <pid> <role> <label> [scope]      AXPress; refused without an AXPress action
//   set-value <pid> <role> <label> <value> [scope]  focus, then set AXValue
//   select-row <pid> <label>           select the outline/table row whose text is <label>
//   menu <pid> [<bar item> <item>...]  press a menu-bar item by title path; no path lists bar items
//   main-window <pid> <title>          make the window whose title contains <title> main
//   close-window <pid> <title>         press that window's close button
//   cancel-menu <pid>                  dismiss open menus with AXCancel
//   center <pid> <role> <label> [scope]     "<x> <y>" center of the element frame
//   click <pid> <x> <y> [--stay]       guarded physical click; focus and cursor return unless --stay
//   hover <pid> <x> <y>                guarded cursor move; focus and cursor stay
//   cursor                             cursor position "<x> <y>"
//   warp <x> <y>                       move the cursor without an event
//
// Positions are global with a top-left origin (AX, CGEvent, and CGWindowList
// agree). Exit codes: 0 ok, 1 not found or refused, 2 preflight skipped or
// wait timeout, 3 press delivery uncertain (AX timed out), 64 usage.

import AppKit
import ApplicationServices
import CoreGraphics
import Foundation

func fail(_ message: String, code: Int32 = 1) -> Never {
  FileHandle.standardError.write(Data("sv-tool: \(message)\n".utf8))
  exit(code)
}

// MARK: - Arguments

struct Arguments {
  var positional: [String] = []
  var options: [String: String] = [:]
  var flags: Set<String> = []

  init(_ raw: ArraySlice<String>) {
    let valued: Set<String> = ["--within", "--near", "--after", "--window", "--depth", "--timeout"]
    var iterator = raw.makeIterator()
    while let token = iterator.next() {
      if valued.contains(token) {
        guard let value = iterator.next() else { fail("\(token) needs a value", code: 64) }
        options[token] = value
      } else if token.hasPrefix("--") {
        flags.insert(token)
      } else {
        positional.append(token)
      }
    }
  }

  func pid(at index: Int, usage: String) -> pid_t {
    guard positional.count > index, let pid = pid_t(positional[index]), pid > 0 else { fail("usage: \(usage)", code: 64) }
    return pid
  }

  func string(at index: Int, usage: String) -> String {
    guard positional.count > index else { fail("usage: \(usage)", code: 64) }
    return positional[index]
  }
}

// MARK: - AX access

func attribute(_ element: AXUIElement, _ name: String) -> AnyObject? {
  var value: AnyObject?
  return AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success ? value : nil
}

func children(_ element: AXUIElement) -> [AXUIElement] {
  (attribute(element, kAXChildrenAttribute) as? [AXUIElement]) ?? []
}

func string(_ element: AXUIElement, _ name: String) -> String? {
  guard let value = attribute(element, name) else { return nil }
  if let text = value as? String { return text }
  if CFGetTypeID(value) == CFBooleanGetTypeID() { return CFBooleanGetValue((value as! CFBoolean)) ? "1" : "0" }
  if let number = value as? NSNumber { return number.stringValue }
  return nil
}

func bool(_ element: AXUIElement, _ name: String) -> Bool? {
  guard let value = attribute(element, name), CFGetTypeID(value) == CFBooleanGetTypeID() else { return nil }
  return CFBooleanGetValue((value as! CFBoolean))
}

func role(_ element: AXUIElement) -> String { string(element, kAXRoleAttribute) ?? "" }

func labels(_ element: AXUIElement) -> [String] {
  [kAXTitleAttribute, kAXDescriptionAttribute, kAXValueAttribute, kAXPlaceholderValueAttribute, kAXIdentifierAttribute]
    .compactMap { string(element, $0) }.filter { !$0.isEmpty }
}

func actions(_ element: AXUIElement) -> [String] {
  var names: CFArray?
  AXUIElementCopyActionNames(element, &names)
  return (names as? [String]) ?? []
}

func frame(_ element: AXUIElement) -> CGRect? {
  guard let position = attribute(element, kAXPositionAttribute), let size = attribute(element, kAXSizeAttribute)
  else { return nil }
  var origin = CGPoint.zero
  var extent = CGSize.zero
  AXValueGetValue(position as! AXValue, .cgPoint, &origin)
  AXValueGetValue(size as! AXValue, .cgSize, &extent)
  return CGRect(origin: origin, size: extent)
}

// Walk windows only: the menu bar's Recent Items submenu can stall a walk.
func windows(of pid: pid_t) -> [AXUIElement] {
  (attribute(AXUIElementCreateApplication(pid), kAXWindowsAttribute) as? [AXUIElement]) ?? []
}

func descendants(_ element: AXUIElement, depth: Int = 0, limit: Int = 80) -> [AXUIElement] {
  guard depth < limit else { return [] }
  return [element] + children(element).flatMap { descendants($0, depth: depth + 1, limit: limit) }
}

func find(pid: pid_t, role wanted: String, label: String, scope options: [String: String]) -> [AXUIElement] {
  var roots = windows(of: pid)
  for option in ["--within", "--near"] {
    guard let anchor = options[option] else { continue }
    guard let element = roots.flatMap({ descendants($0) }).first(where: { labels($0).contains(anchor) }) else {
      fail("no element labelled \"\(anchor)\" for \(option)")
    }
    var scope = element
    if option == "--near", let parent = attribute(element, kAXParentAttribute) { scope = parent as! AXUIElement }
    roots = [scope]
  }
  var ordered = roots.flatMap { descendants($0) }
  // --after pairs a control with the label text before it, as in a Settings
  // row whose switch has no label of its own: the first match wins.
  if let anchor = options["--after"] {
    guard let index = ordered.firstIndex(where: { labels($0).contains(anchor) }) else {
      fail("no element labelled \"\(anchor)\" for --after")
    }
    ordered = Array(ordered[(index + 1)...])
  }
  // "" matches unlabelled elements, such as a split button's chevron; "*"
  // matches any label.
  var matches: [AXUIElement] = []
  for element in ordered
  where (wanted == "any" || role(element) == wanted)
    && (label == "*" || (label.isEmpty ? labels(element).isEmpty : labels(element).contains(label)))
  {
    // An open menu is reachable from its button and from its menu window.
    if !matches.contains(where: { CFEqual($0, element) }) { matches.append(element) }
  }
  if options["--after"] != nil { return Array(matches.prefix(1)) }
  return matches
}

func findOne(_ args: Arguments, usage: String) -> AXUIElement {
  let pid = args.pid(at: 0, usage: usage)
  let wanted = args.string(at: 1, usage: usage)
  let label = args.string(at: 2, usage: usage)
  let matches = find(pid: pid, role: wanted, label: label, scope: args.options)
  guard matches.count == 1 else {
    fail("expected one \(wanted) labelled \"\(label)\", found \(matches.count); add --within, --near, --after, or a narrower role")
  }
  return matches[0]
}

func describe(_ element: AXUIElement) -> String {
  var parts = [role(element)]
  if let subrole = string(element, kAXSubroleAttribute) { parts.append("(\(subrole))") }
  for name in [kAXTitleAttribute, kAXDescriptionAttribute, kAXPlaceholderValueAttribute] {
    if let text = string(element, name), !text.isEmpty { parts.append("\"\(text.prefix(80))\"") }
  }
  if let value = string(element, kAXValueAttribute), !value.isEmpty {
    parts.append("= \"\(value.prefix(60).replacingOccurrences(of: "\n", with: "⏎"))\"")
  }
  if let identifier = string(element, kAXIdentifierAttribute), !identifier.isEmpty { parts.append("#\(identifier)") }
  var state: [String] = []
  if bool(element, kAXEnabledAttribute) == false { state.append("disabled") }
  if bool(element, kAXSelectedAttribute) == true { state.append("selected") }
  if bool(element, kAXFocusedAttribute) == true { state.append("focused") }
  if bool(element, kAXExpandedAttribute) == true { state.append("expanded") }
  if !state.isEmpty { parts.append("[\(state.joined(separator: ","))]") }
  let shown = actions(element).filter { !["AXScrollToVisible", "AXShowDefaultUI", "AXShowAlternateUI"].contains($0) }
    .map { $0.hasPrefix("Name:") ? String($0.dropFirst(5).prefix { $0 != "\n" }) : $0.replacingOccurrences(of: "AX", with: "") }
  if !shown.isEmpty { parts.append("{\(shown.joined(separator: ","))}") }
  if let rect = frame(element) {
    parts.append("@\(Int(rect.minX)),\(Int(rect.minY)) \(Int(rect.width))x\(Int(rect.height))")
  }
  return parts.joined(separator: " ")
}

// MARK: - Windows and focus

struct WindowRow {
  let id: Int
  let pid: pid_t
  let owner: String
  let layer: Int
  let alpha: Double
  let bounds: CGRect
  let title: String
}

// Front-to-back order, as CGWindowList returns it.
func onScreenWindows() -> [WindowRow] {
  let list =
    (CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
      as? [[String: Any]]) ?? []
  return list.compactMap { info in
    guard let id = info[kCGWindowNumber as String] as? Int,
      let pid = info[kCGWindowOwnerPID as String] as? pid_t,
      let raw = info[kCGWindowBounds as String] as? NSDictionary,
      let bounds = CGRect(dictionaryRepresentation: raw)
    else { return nil }
    return WindowRow(
      id: id, pid: pid, owner: info[kCGWindowOwnerName as String] as? String ?? "",
      layer: info[kCGWindowLayer as String] as? Int ?? 0, alpha: info[kCGWindowAlpha as String] as? Double ?? 1,
      bounds: bounds, title: info[kCGWindowName as String] as? String ?? "")
  }
}

func frontPID() -> pid_t { NSWorkspace.shared.frontmostApplication?.processIdentifier ?? -1 }

func activate(_ pid: pid_t) -> Bool {
  guard let app = NSRunningApplication(processIdentifier: pid) else { return false }
  _ = app.activate(options: [.activateAllWindows])
  // Cooperative activation can make the app frontmost without ordering its
  // windows in front; the AX frontmost flag does both.
  AXUIElementSetAttributeValue(AXUIElementCreateApplication(pid), kAXFrontmostAttribute as CFString, kCFBooleanTrue)
  let deadline = Date().addingTimeInterval(1.5)
  while Date() < deadline {
    if frontPID() == pid { return true }
    RunLoop.current.run(until: Date().addingTimeInterval(0.02))
  }
  return frontPID() == pid
}

func window(of pid: pid_t, titled needle: String) -> AXUIElement {
  let all = windows(of: pid)
  let matches = all.filter { (string($0, kAXTitleAttribute) ?? "").lowercased().contains(needle.lowercased()) }
  guard matches.count == 1 else {
    fail("expected one window titled *\(needle)*, found \(matches.count) in \(all.map { string($0, kAXTitleAttribute) ?? "" })")
  }
  return matches[0]
}

// MARK: - Physical input

func postMouse(_ type: CGEventType, at point: CGPoint) {
  let source = CGEventSource(stateID: .hidSystemState)
  let event = CGEvent(mouseEventSource: source, mouseType: type, mouseCursorPosition: point, mouseButton: .left)
  if type != .mouseMoved { event?.setIntegerValueField(.mouseEventClickState, value: 1) }
  event?.post(tap: .cghidEventTap)
  usleep(30_000)
}

func raiseWindow(of pid: pid_t, containing point: CGPoint) {
  for candidate in windows(of: pid) where frame(candidate)?.contains(point) == true {
    AXUIElementPerformAction(candidate, kAXRaiseAction as CFString)
    return
  }
}

func physical(_ args: Arguments, hover: Bool) {
  let usage = "\(hover ? "hover" : "click") <pid> <x> <y>\(hover ? "" : " [--stay]")"
  let pid = args.pid(at: 0, usage: usage)
  guard let x = Double(args.string(at: 1, usage: usage)), let y = Double(args.string(at: 2, usage: usage)) else {
    fail("usage: \(usage)", code: 64)
  }
  let point = CGPoint(x: x, y: y)
  let stay = hover || args.flags.contains("--stay")
  guard onScreenWindows().contains(where: { $0.pid == pid && $0.bounds.contains(point) }) else {
    fail("point \(Int(x)),\(Int(y)) is outside every pid \(pid) window; nothing sent")
  }
  let previous = frontPID()
  let cursor = CGEvent(source: nil)?.location
  guard activate(pid) else { fail("pid \(pid) did not become frontmost; nothing sent") }
  raiseWindow(of: pid, containing: point)
  usleep(150_000)
  // The topmost visible window under the point, at any non-desktop layer
  // (menu bar, panels, popovers included), must belong to the target, or the
  // event would land in another app. The cursor sprite is skipped.
  let top = onScreenWindows().first {
    $0.layer >= 0 && $0.alpha > 0 && $0.owner != "Window Server" && $0.bounds.contains(point)
  }
  guard let top, top.pid == pid else {
    if !stay, previous > 0 { _ = activate(previous) }
    let owner = top.map { "\($0.owner) pid \($0.pid) window \($0.id)" } ?? "nothing"
    fail("point \(Int(x)),\(Int(y)) is covered by \(owner); nothing sent")
  }
  guard frontPID() == pid else { fail("focus moved away; nothing sent") }
  if hover {
    // Tracking areas react to movement, and a just-activated app can drop
    // the first event: approach the point in small steps.
    for dx in [-6.0, -3.0, 0.0] {
      postMouse(.mouseMoved, at: CGPoint(x: point.x + dx, y: point.y))
      usleep(80_000)
    }
  } else {
    for type in [CGEventType.mouseMoved, .leftMouseDown, .leftMouseUp] { postMouse(type, at: point) }
    usleep(150_000)
    if !stay {
      if let cursor { CGWarpMouseCursorPosition(cursor) }
      if previous > 0, previous != pid { _ = activate(previous) }
    }
  }
  print("ok \(hover ? "hover" : "click") \(Int(x)),\(Int(y)) window=\(top.id) previous=\(previous)")
}

// MARK: - Commands

let all = CommandLine.arguments
guard all.count >= 2 else { fail("usage: sv-tool <command> ...; see the header of sv-tool.swift", code: 64) }
let args = Arguments(all.dropFirst(2))
// The default AX messaging timeout is about 6 s; a press that opens a menu
// blocks for all of it.
AXUIElementSetMessagingTimeout(AXUIElementCreateSystemWide(), 2.0)

switch all[1] {
case "preflight":
  var reasons: [String] = []
  if !AXIsProcessTrusted() { reasons.append("accessibility_not_trusted") }
  let screen = CGPreflightScreenCaptureAccess()
  let status = reasons.isEmpty ? "READY" : "SKIPPED"
  let json: [String: Any] = [
    "status": status, "reasons": reasons, "accessibility": AXIsProcessTrusted(), "screen_recording": screen,
  ]
  let data = try! JSONSerialization.data(withJSONObject: json, options: [.sortedKeys])
  print(String(decoding: data, as: UTF8.self))
  exit(reasons.isEmpty ? 0 : 2)

case "front":
  print(frontPID())

case "activate":
  exit(activate(args.pid(at: 0, usage: "activate <pid>")) ? 0 : 1)

case "windows":
  let pid = args.pid(at: 0, usage: "windows <pid> [title]")
  let needle = args.positional.count > 1 ? args.positional[1].lowercased() : nil
  let rows = onScreenWindows().filter { $0.pid == pid && (needle == nil || $0.title.lowercased().contains(needle!)) }
  for row in rows {
    print(row.id, Int(row.bounds.minX), Int(row.bounds.minY), Int(row.bounds.width), Int(row.bounds.height), row.title)
  }
  exit(rows.isEmpty ? 1 : 0)

case "tree":
  let pid = args.pid(at: 0, usage: "tree <pid> [--window T] [--depth N]")
  let limit = Int(args.options["--depth"] ?? "") ?? 40
  var roots = windows(of: pid)
  if let title = args.options["--window"] { roots = [window(of: pid, titled: title)] }
  func dump(_ element: AXUIElement, _ depth: Int) {
    guard depth <= limit else { return }
    let line = describe(element)
    // Unlabelled layout groups add depth but no information.
    let quiet = ["AXGroup", "AXSplitGroup", "AXLayoutArea"].contains(role(element)) && labels(element).isEmpty
      && actions(element).allSatisfy { $0 == "AXScrollToVisible" || $0 == "AXShowMenu" }
    if !quiet { print(String(repeating: "  ", count: depth) + line) }
    for child in children(element) { dump(child, quiet ? depth : depth + 1) }
  }
  roots.forEach { dump($0, 0) }

case "find":
  let usage = "find <pid> <role|any> <label> [scope]"
  let matches = find(
    pid: args.pid(at: 0, usage: usage), role: args.string(at: 1, usage: usage), label: args.string(at: 2, usage: usage),
    scope: args.options)
  matches.forEach { print(describe($0)) }
  exit(matches.isEmpty ? 1 : 0)

case "get":
  let element = findOne(args, usage: "get <pid> <role> <label> [scope]")
  var json: [String: Any] = ["role": role(element), "labels": labels(element), "actions": actions(element)]
  json["value"] = string(element, kAXValueAttribute)
  json["enabled"] = bool(element, kAXEnabledAttribute)
  json["selected"] = bool(element, kAXSelectedAttribute)
  json["focused"] = bool(element, kAXFocusedAttribute)
  json["expanded"] = bool(element, kAXExpandedAttribute)
  if let rect = frame(element) {
    json["frame"] = ["x": Int(rect.minX), "y": Int(rect.minY), "w": Int(rect.width), "h": Int(rect.height)]
  }
  let data = try! JSONSerialization.data(withJSONObject: json, options: [.sortedKeys])
  print(String(decoding: data, as: UTF8.self))

case "wait":
  let usage = "wait <pid> <role> <label> [scope] [--gone] [--timeout MS]"
  let pid = args.pid(at: 0, usage: usage)
  let wanted = args.string(at: 1, usage: usage)
  let label = args.string(at: 2, usage: usage)
  let gone = args.flags.contains("--gone")
  let timeout = Double(args.options["--timeout"] ?? "") ?? 5000
  let started = Date()
  while Date().timeIntervalSince(started) * 1000 < timeout {
    let present = !find(pid: pid, role: wanted, label: label, scope: args.options).isEmpty
    if present != gone {
      print("ok \(gone ? "gone" : "present") after \(Int(Date().timeIntervalSince(started) * 1000))ms")
      exit(0)
    }
    usleep(100_000)
  }
  fail("timed out after \(Int(timeout))ms waiting for \(wanted) \"\(label)\" to be \(gone ? "gone" : "present")", code: 2)

case "press":
  let element = findOne(args, usage: "press <pid> <role> <label> [scope]")
  guard actions(element).contains(kAXPressAction) else {
    fail("\(describe(element)) has no AXPress action; a press would only report success")
  }
  let label = describe(element)
  let result = AXUIElementPerformAction(element, kAXPressAction as CFString)
  if result == .cannotComplete {
    // A press that opens a menu returns only after the menu closes, so AX
    // times out while the menu is open. Delivery is uncertain: observe.
    print("uncertain press \(label): AX timed out (-25204); observe the result before you act again")
    exit(3)
  }
  guard result == .success else { fail("AXPress failed: \(result.rawValue)") }
  print("ok press \(label)")

case "set-value":
  let usage = "set-value <pid> <role> <label> <value> [scope]"
  let element = findOne(args, usage: usage)
  let value = args.string(at: 3, usage: usage)
  AXUIElementSetAttributeValue(element, kAXFocusedAttribute as CFString, kCFBooleanTrue)
  let result = AXUIElementSetAttributeValue(element, kAXValueAttribute as CFString, value as CFString)
  guard result == .success else { fail("setting AXValue failed: \(result.rawValue)") }
  print("ok set-value \(describe(element))")

case "select-row":
  let pid = args.pid(at: 0, usage: "select-row <pid> <label>")
  let label = args.string(at: 1, usage: "select-row <pid> <label>")
  let tables = windows(of: pid).flatMap { descendants($0) }.filter { [kAXOutlineRole, kAXTableRole].contains(role($0)) }
  for table in tables {
    let rows = (attribute(table, kAXRowsAttribute) as? [AXUIElement]) ?? []
    if let row = rows.first(where: { descendants($0, limit: 8).contains { labels($0).contains(label) } }) {
      let result = AXUIElementSetAttributeValue(table, kAXSelectedRowsAttribute as CFString, [row] as CFArray)
      guard result == .success else { fail("setting AXSelectedRows failed: \(result.rawValue)") }
      print("ok select-row \(label)")
      exit(0)
    }
  }
  fail("no outline or table row with text \"\(label)\"")

case "menu":
  let pid = args.pid(at: 0, usage: "menu <pid> [<bar item> <item>...]")
  guard let bar = attribute(AXUIElementCreateApplication(pid), kAXMenuBarAttribute) else { fail("pid \(pid) has no menu bar") }
  let path = Array(args.positional.dropFirst())
  func title(_ element: AXUIElement) -> String { string(element, kAXTitleAttribute) ?? "" }
  if path.isEmpty {
    children(bar as! AXUIElement).forEach { print(title($0)) }
    exit(0)
  }
  // Follow only the named path: a full walk can stall in Recent Items.
  var current = bar as! AXUIElement
  for (index, name) in path.enumerated() {
    var candidates = children(current)
    if index > 0 { candidates = candidates.flatMap { role($0) == kAXMenuRole ? children($0) : [$0] } }
    guard let next = candidates.first(where: { title($0) == name }) else {
      fail("no menu item \"\(name)\"; found: \(candidates.map(title).filter { !$0.isEmpty }.joined(separator: ", "))")
    }
    current = next
  }
  if bool(current, kAXEnabledAttribute) == false { fail("menu item \"\(path.last!)\" is disabled") }
  let result = AXUIElementPerformAction(current, kAXPressAction as CFString)
  guard result == .success else { fail("AXPress failed: \(result.rawValue)") }
  print("ok menu \(path.joined(separator: " > "))")

case "main-window":
  let pid = args.pid(at: 0, usage: "main-window <pid> <title>")
  let target = window(of: pid, titled: args.string(at: 1, usage: "main-window <pid> <title>"))
  let result = AXUIElementSetAttributeValue(target, kAXMainAttribute as CFString, kCFBooleanTrue)
  guard result == .success else { fail("setting AXMain failed: \(result.rawValue)") }
  print("ok main-window \(string(target, kAXTitleAttribute) ?? "")")

case "close-window":
  let pid = args.pid(at: 0, usage: "close-window <pid> <title>")
  let target = window(of: pid, titled: args.string(at: 1, usage: "close-window <pid> <title>"))
  let title = string(target, kAXTitleAttribute) ?? ""
  guard let button = attribute(target, kAXCloseButtonAttribute) else { fail("window has no close button") }
  let result = AXUIElementPerformAction(button as! AXUIElement, kAXPressAction as CFString)
  guard result == .success else { fail("AXPress on the close button failed: \(result.rawValue)") }
  print("ok close-window \(title)")

case "cancel-menu":
  let pid = args.pid(at: 0, usage: "cancel-menu <pid>")
  let open = windows(of: pid).flatMap { descendants($0) }.filter { role($0) == kAXMenuRole }
  guard !open.isEmpty else { fail("no open menu") }
  open.forEach { AXUIElementPerformAction($0, kAXCancelAction as CFString) }
  print("ok cancel-menu \(open.count)")

case "center":
  let element = findOne(args, usage: "center <pid> <role> <label> [scope]")
  guard let rect = frame(element), rect.width > 0, rect.height > 0 else { fail("element has no frame") }
  print(Int(rect.midX), Int(rect.midY))

case "click":
  physical(args, hover: false)

case "hover":
  physical(args, hover: true)

case "cursor":
  let location = CGEvent(source: nil)?.location ?? .zero
  print(Int(location.x), Int(location.y))

case "warp":
  guard args.positional.count >= 2, let x = Double(args.positional[0]), let y = Double(args.positional[1]) else {
    fail("usage: warp <x> <y>", code: 64)
  }
  CGWarpMouseCursorPosition(CGPoint(x: x, y: y))

default:
  fail("unknown command \(all[1])", code: 64)
}

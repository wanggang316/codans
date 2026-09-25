import AppKit
import ApplicationServices

// Minimal AX driver for an isolated test instance, addressed by pid so it
// never resolves to another process with the same name.
//   ax tree <pid> [maxDepth]
//   ax press <pid> <label>            AXPress the first element whose title/description/identifier/value == label
//   ax menu <pid> <menuBarItem> <menuItem>
//   ax select-row <pid> <text>        select the outline/table row containing static text == text
//   ax wait <pid> <label> [seconds]   exit 0 once an element with label exists

func attr(_ e: AXUIElement, _ name: String) -> AnyObject? {
  var value: AnyObject?
  guard AXUIElementCopyAttributeValue(e, name as CFString, &value) == .success else { return nil }
  return value
}
func str(_ e: AXUIElement, _ name: String) -> String? {
  if let s = attr(e, name) as? String, !s.isEmpty { return s }
  return nil
}
func children(_ e: AXUIElement) -> [AXUIElement] {
  (attr(e, kAXChildrenAttribute) as? [AXUIElement]) ?? []
}
func labels(_ e: AXUIElement) -> [String] {
  [kAXTitleAttribute, kAXDescriptionAttribute, kAXIdentifierAttribute, kAXValueAttribute]
    .compactMap { str(e, $0) }
}
func walk(_ e: AXUIElement, depth: Int = 0, max: Int = 60, _ visit: (AXUIElement, Int) -> Bool) -> Bool {
  if visit(e, depth) { return true }
  guard depth < max else { return false }
  for c in children(e) where walk(c, depth: depth + 1, max: max, visit) { return true }
  return false
}
func find(_ root: AXUIElement, _ label: String) -> AXUIElement? {
  var hit: AXUIElement?
  _ = walk(root) { e, _ in
    if labels(e).contains(label) { hit = e; return true }
    return false
  }
  return hit
}

let args = CommandLine.arguments
guard args.count >= 3, let pid = pid_t(args[2]) else {
  FileHandle.standardError.write("usage: ax tree|press|menu|select-row|wait <pid> ...\n".data(using: .utf8)!)
  exit(2)
}
let app = AXUIElementCreateApplication(pid)

switch args[1] {
case "tree":
  let maxDepth = args.count > 3 ? Int(args[3]) ?? 12 : 12
  _ = walk(app, max: maxDepth) { e, d in
    let role = str(e, kAXRoleAttribute) ?? "?"
    let l = labels(e).map { $0.replacingOccurrences(of: "\n", with: " ").prefix(80) }.joined(separator: " | ")
    print(String(repeating: "  ", count: d) + role + (l.isEmpty ? "" : "  [" + l + "]"))
    return false
  }
case "press":
  guard let e = find(app, args[3]) else { print("not found: \(args[3])"); exit(1) }
  let r = AXUIElementPerformAction(e, kAXPressAction as CFString)
  print(r == .success ? "pressed \(args[3])" : "press failed \(r.rawValue)")
  exit(r == .success ? 0 : 1)
case "menu":
  guard let bar = attr(app, kAXMenuBarAttribute) else { print("no menu bar"); exit(1) }
  let barEl = bar as! AXUIElement
  guard let top = children(barEl).first(where: { str($0, kAXTitleAttribute) == args[3] }) else {
    print("no menu \(args[3])"); exit(1)
  }
  guard let item = find(top, args[4]) else { print("no item \(args[4])"); exit(1) }
  let r = AXUIElementPerformAction(item, kAXPressAction as CFString)
  print(r == .success ? "menu \(args[3]) > \(args[4])" : "menu failed \(r.rawValue)")
case "select-row":
  var done = false
  _ = walk(app) { e, _ in
    let role = str(e, kAXRoleAttribute)
    guard role == kAXOutlineRole || role == kAXTableRole else { return false }
    for row in (attr(e, kAXRowsAttribute) as? [AXUIElement]) ?? [] where find(row, args[3]) != nil {
      AXUIElementSetAttributeValue(e, kAXSelectedRowsAttribute as CFString, [row] as CFArray)
      done = true
      return true
    }
    return false
  }
  print(done ? "selected \(args[3])" : "row not found: \(args[3])")
  exit(done ? 0 : 1)
case "wait":
  let deadline = Date().addingTimeInterval(args.count > 4 ? Double(args[4]) ?? 10 : 10)
  while Date() < deadline {
    if find(app, args[3]) != nil { print("found \(args[3])"); exit(0) }
    usleep(250_000)
  }
  print("timeout waiting for \(args[3])")
  exit(1)
default:
  print("unknown command \(args[1])")
  exit(2)
}

import ApplicationServices
import Foundation

// Prints every labeled element under the Agents View list of one process.
let pid = pid_t(CommandLine.arguments[1])!
let app = AXUIElementCreateApplication(pid)

func attr(_ e: AXUIElement, _ name: String) -> AnyObject? {
  var v: AnyObject?
  return AXUIElementCopyAttributeValue(e, name as CFString, &v) == .success ? v : nil
}
func kids(_ e: AXUIElement) -> [AXUIElement] { attr(e, "AXChildren") as? [AXUIElement] ?? [] }

func find(_ e: AXUIElement, _ ident: String, _ depth: Int = 0) -> AXUIElement? {
  if depth > 60 { return nil }
  if attr(e, "AXIdentifier") as? String == ident { return e }
  for k in kids(e) { if let hit = find(k, ident, depth + 1) { return hit } }
  return nil
}
func dump(_ e: AXUIElement, _ depth: Int) {
  let role = attr(e, "AXRole") as? String ?? ""
  let ident = attr(e, "AXIdentifier") as? String ?? ""
  let desc = attr(e, "AXDescription") as? String ?? ""
  let help = attr(e, "AXHelp") as? String ?? ""
  if !desc.isEmpty || !ident.isEmpty || !help.isEmpty {
    print(String(repeating: "  ", count: depth) + "\(role) id=\(ident) label=\(desc) help=\(help)")
  }
  for k in kids(e) { dump(k, depth + 1) }
}
guard let list = find(app, "agentState.sidebarPanel.list") else { print("no list"); exit(1) }
dump(list, 0)

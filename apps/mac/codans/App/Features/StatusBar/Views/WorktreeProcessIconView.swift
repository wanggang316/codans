import CodansCore
import Foundation
import SwiftUI

enum WorktreeProcessIcon: Equatable {
  case agent(AgentKind)
  case asset(String)
  case terminal

  static func resolve(processName: String, agentKind: AgentKind?) -> Self {
    if let agentKind { return .agent(agentKind) }
    // npm and pnpm can set their process title to include the running script.
    let executable = processName.split(whereSeparator: \.isWhitespace).first.map(String.init) ?? ""
    switch executable.lowercased() {
    case "node", "nodejs": return .asset("process-nodejs")
    case "npm", "npx": return .asset("process-npm")
    case "pnpm", "pnpx": return .asset("process-pnpm")
    case "go": return .asset("process-go")
    case "cargo", "rustc", "rustup": return .asset("process-rust")
    case "docker", "docker-compose": return .asset("process-docker")
    case "git": return .asset("process-git")
    default:
      if executable.range(of: #"^python(?:[23](?:\.[0-9]+)?)?$"#, options: .regularExpression) != nil {
        return .asset("process-python")
      }
      return .terminal
    }
  }
}

struct WorktreeProcessIconView: View {
  let entry: WorktreeProcessEntry

  var body: some View {
    Group {
      switch WorktreeProcessIcon.resolve(processName: entry.processName, agentKind: entry.agentKind) {
      case .agent(let kind):
        AgentLogoView(kind: kind, size: 14)
      case .asset(let name):
        Image(name)
          .resizable()
          .scaledToFit()
      case .terminal:
        Image(systemName: "terminal")
          .resizable()
          .scaledToFit()
      }
    }
    .frame(width: 14, height: 14)
    .foregroundStyle(.secondary)
    .accessibilityHidden(true)
  }
}

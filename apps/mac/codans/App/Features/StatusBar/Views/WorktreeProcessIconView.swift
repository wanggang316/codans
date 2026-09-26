import CodansCore
import Foundation
import SwiftUI

enum WorktreeProcessIcon: Equatable {
  case agent(AgentKind)
  case command(CommandIconRef)
  case terminal

  /// Resolves through `CommandIconCatalog`, the same table command icons
  /// use, so a tool reads the same in the process list and in Commands.
  static func resolve(processName: String, agentKind: AgentKind?) -> Self {
    if let agentKind { return .agent(agentKind) }
    // npm and pnpm can set their process title to include the running script.
    let executable = processName.split(whereSeparator: \.isWhitespace).first.map(String.init) ?? ""
    return CommandIconCatalog.toolIcon(forExecutable: executable).map(Self.command) ?? .terminal
  }
}

struct WorktreeProcessIconView: View {
  let entry: WorktreeProcessEntry

  var body: some View {
    Group {
      switch WorktreeProcessIcon.resolve(processName: entry.processName, agentKind: entry.agentKind) {
      case .agent(let kind):
        AgentLogoView(kind: kind, size: 14)
      case .command(.mark(let mark)):
        Image(mark.assetName)
          .resizable()
          .scaledToFit()
      case .command(.symbol(let name)):
        Image(systemName: name)
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

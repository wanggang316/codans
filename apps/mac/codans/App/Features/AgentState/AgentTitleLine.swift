import CodansCore
import SwiftUI

/// First line of a `normal` Agents View row: the agent title, else the agent
/// display name in the same style (ADR 0009).
///
/// The live title is read here, not in the row or the panel: reading
/// `AgentStateStore` inside this body scopes the `@Observable` tracking to
/// this line, so a retitle does not re-render the list. The single-line
/// limit keeps the row height fixed for any text.
struct AgentTitleLine: View {
  let paneID: PaneID
  let agentTitle: () -> AgentStateStore.AgentTitle?
  @State var presentation: AgentTitlePresentation

  var body: some View {
    let title = agentTitle()
    Text(presentation.rowText)
      .font(.subheadline)
      .fontWeight(.regular)
      .foregroundStyle(.primary)
      .lineLimit(1)
      .truncationMode(.tail)
      .accessibilityIdentifier("agentState.row.\(paneID).title")
      .onChange(of: title?.text, initial: true) { _, text in
        presentation.update(title: text)
      }
  }
}

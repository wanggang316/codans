import CodansCore
import SwiftUI

/// First line of a `normal` Agents View row: what the agent is doing now,
/// else its display name in the same style.
///
/// The live text is read here, not in the row or the panel: reading
/// `AgentStateStore` inside this body scopes the `@Observable` tracking to
/// this line, so a retitle does not re-render the list. The single-line
/// limit keeps the row height fixed for any text.
struct AgentActivityLine: View {
  let paneID: PaneID
  let activityText: () -> String?
  @State var activity: AgentActivityPresentation

  var body: some View {
    Text(activity.rowText)
      .font(.subheadline)
      .foregroundStyle(.primary)
      .lineLimit(1)
      .truncationMode(.tail)
      .accessibilityIdentifier("agentState.row.\(paneID).activity")
      .onChange(of: activityText(), initial: true) { _, text in
        activity.update(activity: text)
      }
  }
}

import CodansCore
import SwiftUI

/// What Create will produce: the folder tree with each member's branch, and
/// behind a disclosure the git commands in the order they run.
struct WorkspacePreviewPanel: View {
  let plan: WorkspacePlan
  let showCommands: Bool
  let onShowCommandsChanged: (Bool) -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      HStack {
        Text("Will create").font(.callout)
        Spacer()
        Toggle(
          "Show commands",
          isOn: Binding(get: { showCommands }, set: onShowCommandsChanged)
        )
        .toggleStyle(.checkbox)
        .font(.caption)
        .disabled(plan.members.isEmpty)
      }
      if plan.members.isEmpty {
        Text("Add repositories above; the folder layout appears here.")
          .font(.caption)
          .foregroundStyle(.secondary)
      } else {
        VStack(alignment: .leading, spacing: 1) {
          ForEach(Array(WorkspaceCommandPreview.treeLines(for: plan).enumerated()), id: \.offset) { _, line in
            Text(line)
              .font(.caption.monospaced())
              .foregroundStyle(.secondary)
              .lineLimit(1)
              .truncationMode(.middle)
          }
        }
        if showCommands {
          ScrollView(.horizontal) {
            VStack(alignment: .leading, spacing: 1) {
              ForEach(Array(WorkspaceCommandPreview.commands(for: plan).enumerated()), id: \.offset) { _, line in
                Text(line)
                  .font(.caption2.monospaced())
                  .foregroundStyle(.secondary)
                  .textSelection(.enabled)
              }
            }
            .padding(8)
          }
          .frame(maxHeight: 120)
          .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 6))
        }
      }
    }
  }
}

import AppKit
import SwiftUI

/// Settings → Workflows → "Ask an Agent…": a prompt to paste into a coding
/// agent's pane. Writing a workflow is exactly what the bundled
/// `codans-workflow` skill teaches, so the prompt names it, says where the
/// file goes, and asks the agent to validate before it reports back.
struct AskAgentForWorkflowSheet: View {
  let userDirectory: String
  let onDone: () -> Void

  @State private var goal = ""
  @State private var copied = false

  private var prompt: String {
    let task =
      goal.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      ? "<describe what the workflow should do: which agents take part and what each step hands to the next>"
      : goal.trimmingCharacters(in: .whitespacesAndNewlines)
    return """
      Use the codans-workflow skill to write a codans Agent Workflow.

      Goal: \(task)

      Save it as \(userDirectory)/<id>.workflow.yaml (or under .codans/workflows/ in this \
      repository if it belongs to the project), then run `codans workflow validate` on the file \
      and fix every error before you tell me it is done.
      """
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      Text("Ask an Agent to Write a Workflow")
        .font(.headline)
      Text("Describe the workflow, copy the prompt, and paste it into an agent's pane.")
        .foregroundStyle(.secondary)
      TextField("What should the workflow do?", text: $goal, axis: .vertical)
        .lineLimit(2...4)
        .textFieldStyle(.roundedBorder)
      ScrollView {
        Text(prompt)
          .font(.callout.monospaced())
          .textSelection(.enabled)
          .frame(maxWidth: .infinity, alignment: .leading)
          .padding(10)
      }
      .frame(height: 150)
      .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
      Label(
        "The agent needs the codans-workflow skill — install it under Developer → Agent Skills.",
        systemImage: "info.circle"
      )
      .font(.caption)
      .foregroundStyle(.secondary)
      HStack {
        Spacer()
        Button("Done", action: onDone)
          .keyboardShortcut(.cancelAction)
        Button(copied ? "Copied" : "Copy Prompt") {
          NSPasteboard.general.clearContents()
          NSPasteboard.general.setString(prompt, forType: .string)
          copied = true
        }
        .keyboardShortcut(.defaultAction)
      }
    }
    .padding(20)
    .frame(width: 520)
    .onChange(of: goal) { copied = false }
  }
}

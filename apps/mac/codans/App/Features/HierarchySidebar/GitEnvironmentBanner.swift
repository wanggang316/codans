import SwiftUI

/// Sidebar banner shown while `git` is unusable machine-wide (`GitEnvironmentStatus.blocked`).
///
/// Deliberately **not** a per-Project failure row: an environment block affects every
/// repository equally, so it gets one banner carrying the one command that fixes all of them,
/// while the Projects below stay listed and untouched. Marking each Project `.failed` would
/// misattribute a machine-setup problem to the user's checkouts and hide their worktrees for a
/// reason that has nothing to do with them.
struct GitEnvironmentBanner: View {
  let block: GitEnvironmentBlock
  let recheck: () -> Void

  @State private var didCopy = false

  var body: some View {
    HStack(alignment: .top, spacing: 8) {
      Image(systemName: "exclamationmark.triangle.fill")
        .foregroundStyle(.orange)
        .accessibilityHidden(true)

      VStack(alignment: .leading, spacing: 6) {
        Text(block.title)
          .font(.callout.weight(.semibold))
        Text(block.explanation)
          .font(.caption)
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)

        if let command = block.remedyCommand {
          HStack(spacing: 6) {
            Text(command)
              .font(.caption.monospaced())
              .textSelection(.enabled)
              .lineLimit(1)
              .truncationMode(.middle)
              .padding(.horizontal, 6)
              .padding(.vertical, 3)
              .background(.quaternary, in: RoundedRectangle(cornerRadius: 4))
            Button {
              copy(command)
            } label: {
              Image(systemName: didCopy ? "checkmark" : "doc.on.doc")
            }
            .buttonStyle(.borderless)
            .help("Copy command")
            .accessibilityLabel(didCopy ? "Command copied" : "Copy command")
          }
        }

        Button("Recheck", action: recheck)
          .controlSize(.small)
      }
    }
    .padding(.horizontal, 12)
    .padding(.vertical, 8)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(.bar)
    .overlay(alignment: .bottom) { Divider() }
    .accessibilityElement(children: .contain)
    .accessibilityLabel("\(block.title). \(block.explanation)")
  }

  private func copy(_ command: String) {
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(command, forType: .string)
    didCopy = true
    // Revert the checkmark so a second copy still reads as a fresh confirmation.
    Task {
      try? await Task.sleep(for: .seconds(2))
      didCopy = false
    }
  }
}

#Preview("License not accepted") {
  GitEnvironmentBanner(block: .xcodeLicenseNotAccepted, recheck: {})
    .frame(width: 280)
}

#Preview("Unknown failure") {
  GitEnvironmentBanner(block: .unknown(detail: "fatal: detected dubious ownership"), recheck: {})
    .frame(width: 280)
}

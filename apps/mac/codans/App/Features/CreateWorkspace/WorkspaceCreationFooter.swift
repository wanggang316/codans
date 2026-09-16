import ComposableArchitecture
import SwiftUI

/// The sheet's bottom row: on the left what still blocks Create or how the
/// run is going, on the right the buttons for the current phase.
struct WorkspaceCreationFooter: View {
  let store: StoreOf<CreateWorkspaceFeature>

  var body: some View {
    HStack(spacing: 12) {
      summary
      Spacer()
      buttons
    }
  }

  @ViewBuilder
  private var summary: some View {
    switch store.creation {
    case .idle:
      let blocking = store.blockingCount
      let warnings = store.warningCount
      if blocking > 0 {
        Button {
          if let id = store.firstOffendingMemberID {
            store.send(.member(id, .toggleExpanded))
          }
        } label: {
          Label(blocking == 1 ? "1 issue" : "\(blocking) issues", systemImage: "exclamationmark.circle.fill")
            .font(.caption)
            .foregroundStyle(.red)
        }
        .buttonStyle(.plain)
        if let first = store.workspaceIssues.first(where: { $0.severity == .blocking }) {
          Text(first.message).font(.caption).foregroundStyle(.secondary)
        }
      } else if warnings > 0 {
        Label(warnings == 1 ? "1 warning" : "\(warnings) warnings", systemImage: "exclamationmark.triangle.fill")
          .font(.caption)
          .foregroundStyle(.orange)
      } else if let info = store.rootIssues.first(where: { $0.severity == .info }) {
        Text(info.message).font(.caption).foregroundStyle(.secondary)
      }
    case .running:
      progressLabel("Creating checkouts…")
    case .finalizing(let text):
      progressLabel(text)
    case .rollingBack:
      progressLabel("Rolling back…")
    case .rolledBack(let failures):
      if failures.isEmpty {
        Label("Rolled back. Nothing was created.", systemImage: "arrow.uturn.backward.circle")
          .font(.caption)
          .foregroundStyle(.secondary)
      } else {
        Label(
          "Rolled back; \(failures.count) item\(failures.count == 1 ? "" : "s") need manual cleanup: \(failures.joined(separator: ", "))",
          systemImage: "exclamationmark.triangle.fill"
        )
        .font(.caption)
        .foregroundStyle(.orange)
        .textSelection(.enabled)
      }
    case .failed(let message):
      Label(message, systemImage: "xmark.circle.fill")
        .font(.caption)
        .foregroundStyle(.red)
        .textSelection(.enabled)
        .lineLimit(2)
    }
  }

  private func progressLabel(_ text: String) -> some View {
    HStack(spacing: 8) {
      ProgressView().controlSize(.small)
      Text(text).font(.caption).foregroundStyle(.secondary)
    }
  }

  @ViewBuilder
  private var buttons: some View {
    switch store.creation {
    case .idle:
      Button("Cancel") { store.send(.cancelButtonTapped) }
        .keyboardShortcut(.cancelAction)
      Button(store.createButtonTitle) { store.send(.createButtonTapped) }
        .keyboardShortcut(.defaultAction)
        .disabled(!store.canCreate)
    case .running, .finalizing:
      Button("Cancel and roll back") { store.send(.cancelButtonTapped) }
        .keyboardShortcut(.cancelAction)
    case .rollingBack:
      Button("Cancel and roll back") {}
        .disabled(true)
    case .rolledBack:
      Button("Edit") { store.send(.editAgainTapped) }
      Button("Done") { store.send(.doneTapped) }
        .keyboardShortcut(.defaultAction)
    case .failed:
      Button("Cancel") { store.send(.cancelButtonTapped) }
        .keyboardShortcut(.cancelAction)
      Button("Edit") { store.send(.editAgainTapped) }
      Button("Retry") { store.send(.retryTapped) }
        .keyboardShortcut(.defaultAction)
    }
  }
}

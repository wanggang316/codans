import ComposableArchitecture
import SwiftUI

/// The sheet's bottom bar, as in the other creation sheets: on the left why
/// Create is unavailable or how the run is going, on the right Cancel and
/// Create. Cancel while checkouts run stops them and removes what they
/// made. A group whose setup failed is kept, so only Done is left.
struct WorkspaceCreationBar: View {
  let store: StoreOf<CreateWorkspaceFeature>

  var body: some View {
    HStack(spacing: 8) {
      status
      Spacer(minLength: 12)
      if store.creation == .createdWithSetupFailures {
        Button("Done") {
          store.send(.cancelButtonTapped)
        }
        .keyboardShortcut(.defaultAction)
      } else {
        Button("Cancel", role: .cancel) {
          store.send(.cancelButtonTapped)
        }
        .keyboardShortcut(.cancelAction)
        .disabled(!canCancel)
        .help(store.creation.isBusy ? "Stop and remove what was created (Esc)" : "Cancel (Esc)")
        Button(store.createButtonTitle) {
          store.send(.createButtonTapped)
        }
        .keyboardShortcut(.defaultAction)
        .disabled(!store.canCreate)
      }
    }
    .padding(.horizontal, 20)
    .padding(.top, 4)
    .padding(.bottom, 20)
  }

  /// Registering a group and running its setup scripts can't stop half
  /// way, and neither can a rollback.
  private var canCancel: Bool {
    switch store.creation {
    case .finalizing, .rollingBack: return false
    default: return true
    }
  }

  @ViewBuilder
  private var status: some View {
    switch store.creation {
    case .idle:
      if let hint = store.createHint {
        Text(hint)
          .foregroundStyle(.secondary)
          .lineLimit(2)
      }
    case .running(let current):
      progress(runningTitle(current))
    case .finalizing(let text):
      progress(text)
    case .rollingBack:
      progress("Removing what was created\u{2026}")
    case .rolledBack(let failures):
      if failures.isEmpty {
        Text("Cancelled. Nothing was created.")
          .foregroundStyle(.secondary)
      } else {
        residuals("Cancelled. Remove by hand:", failures)
      }
    case .failed(let message, let failures):
      if failures.isEmpty {
        Text("Nothing was created. \(message)")
          .foregroundStyle(.red)
          .lineLimit(2)
          .textSelection(.enabled)
          .help(message)
      } else {
        VStack(alignment: .leading, spacing: 2) {
          Text(message)
            .foregroundStyle(.red)
            .lineLimit(2)
            .textSelection(.enabled)
            .help(message)
          residuals("Could not remove:", failures)
        }
      }
    case .createdWithSetupFailures:
      Text("The group was created, but a setup script failed.")
        .foregroundStyle(.orange)
        .lineLimit(2)
    }
  }

  /// What a rollback left behind, one path and reason per line.
  private func residuals(_ title: String, _ failures: [String]) -> some View {
    VStack(alignment: .leading, spacing: 2) {
      Text(title)
        .foregroundStyle(.orange)
      ForEach(Array(failures.enumerated()), id: \.offset) { _, failure in
        Text(failure)
          .foregroundStyle(.orange)
          .lineLimit(2)
          .truncationMode(.middle)
          .textSelection(.enabled)
          .help(failure)
      }
    }
  }

  private func runningTitle(_ current: String?) -> String {
    guard let current else {
      switch store.mode {
      case .addWorkspace: return "Creating the workspace\u{2026}"
      case .addSource: return "Adding the project\u{2026}"
      case .newGroup: return "Creating the group\u{2026}"
      }
    }
    switch store.groupMembers.first(where: { $0.name == current })?.progress {
    case .running(.fetching, _): return "Fetching \(current)\u{2026}"
    default: return "Checking out \(current)\u{2026}"
    }
  }

  private func progress(_ text: String) -> some View {
    HStack(spacing: 8) {
      ProgressView().controlSize(.small)
      Text(text)
        .foregroundStyle(.secondary)
        .lineLimit(1)
    }
  }
}

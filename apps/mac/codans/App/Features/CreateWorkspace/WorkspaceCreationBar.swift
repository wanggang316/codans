import ComposableArchitecture
import SwiftUI

/// The sheet's bottom bar, as in the other creation sheets: on the left why
/// Create is unavailable or how the run is going, on the right Cancel and
/// Create. Cancel during a run stops it and removes what it made.
struct WorkspaceCreationBar: View {
  let store: StoreOf<CreateWorkspaceFeature>

  var body: some View {
    HStack(spacing: 8) {
      status
      Spacer(minLength: 12)
      Button("Cancel", role: .cancel) {
        store.send(.cancelButtonTapped)
      }
      .keyboardShortcut(.cancelAction)
      .disabled(store.creation == .rollingBack)
      .help(store.creation.isBusy ? "Stop and remove what was created (Esc)" : "Cancel (Esc)")
      Button(store.createButtonTitle) {
        store.send(.createButtonTapped)
      }
      .keyboardShortcut(.defaultAction)
      .disabled(!store.canCreate)
    }
    .padding(.horizontal, 20)
    .padding(.top, 4)
    .padding(.bottom, 20)
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
      progress("Removing what was created…")
    case .rolledBack(let failures):
      if failures.isEmpty {
        Text("Cancelled. Nothing was created.")
          .foregroundStyle(.secondary)
      } else {
        Text("Cancelled. Remove by hand: \(failures.joined(separator: ", "))")
          .foregroundStyle(.orange)
          .lineLimit(2)
          .textSelection(.enabled)
          .help(failures.joined(separator: "\n"))
      }
    case .failed(let message):
      Text("Nothing was created. \(message)")
        .foregroundStyle(.red)
        .lineLimit(2)
        .textSelection(.enabled)
        .help(message)
    }
  }

  private func runningTitle(_ current: MemberDraft.ID?) -> String {
    guard let current, let member = store.members[id: current] else { return "Creating…" }
    switch member.progress {
    case .running(.cloning, _): return "Cloning \(member.source.title)…"
    case .running(.fetching, _): return "Fetching \(member.source.title)…"
    default: return "Checking out \(member.source.title)…"
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

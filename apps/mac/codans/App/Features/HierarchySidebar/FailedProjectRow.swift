import SwiftUI

/// Replaces the normal Project row in the sidebar when
/// `project.loadState == .failed(reason:)`. Two-line name + path, a
/// red warning-triangle button that opens a popover with the reason
/// and recovery actions.
struct FailedProjectRow: View {
  let name: String
  let rootPath: String
  let reason: String
  let retry: () -> Void
  let remove: () -> Void

  @State private var showingFailure = false

  var body: some View {
    HStack(spacing: 8) {
      VStack(alignment: .leading, spacing: 2) {
        Text(name)
          .foregroundStyle(.secondary)
        Text(rootPath)
          .font(.caption)
          .foregroundStyle(.tertiary)
          .lineLimit(1)
          .truncationMode(.middle)
      }
      Spacer(minLength: 8)
      Button {
        showingFailure.toggle()
      } label: {
        Image(systemName: "exclamationmark.triangle.fill")
          .accessibilityHidden(true)
      }
      .buttonStyle(.borderless)
      .foregroundStyle(.red)
      .help(reason)
      .accessibilityLabel("Show load failure")
      .popover(isPresented: $showingFailure) {
        VStack(alignment: .leading, spacing: 10) {
          Label("Load failure", systemImage: "exclamationmark.triangle.fill")
            .font(.headline)
            .foregroundStyle(.red)
          Text(reason)
            .font(.callout)
          HStack {
            Spacer()
            Button("Retry", action: retry)
            Button("Remove", role: .destructive, action: remove)
          }
        }
        .padding(16)
        .frame(minWidth: 320)
      }
    }
    .contentShape(Rectangle())
    .contextMenu {
      Button("Retry Loading", action: retry)
      Button("Remove Project", role: .destructive, action: remove)
    }
  }
}

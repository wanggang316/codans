import SwiftUI

/// Replaces the normal Project row in the sidebar when
/// `project.loadState == .failed(reason:)`. Two-line name + path, a
/// red warning-triangle button that opens a popover with the reason
/// and recovery actions.
struct FailedProjectRow: View {
  let name: String
  let rootPath: String
  /// SSH destination for a Server project, `nil` for local. Renders the
  /// network glyph next to the name and prefixes the subtitle so a failed
  /// remote row never reads like a missing *local* folder.
  var remoteAuthority: String?
  let reason: String
  let retry: () -> Void
  let remove: () -> Void

  @State private var showingFailure = false

  var body: some View {
    HStack(spacing: 6) {
      // Reserve the healthy Project header's leading disclosure slot (a
      // 10pt-wide chevron followed by the same 6pt spacing). A failed
      // Project has nothing to expand, so the slot stays empty — drawing
      // no chevron at all would pull the name a glyph's width left of
      // every sibling Project.
      Color.clear
        .frame(width: 10, height: 1)
        .accessibilityHidden(true)
      VStack(alignment: .leading, spacing: 2) {
        HStack(spacing: 4) {
          Text(name)
            .foregroundStyle(.secondary)
          if let remoteAuthority {
            Image(systemName: "tv.badge.wifi")
              .font(.caption2)
              .foregroundStyle(.tertiary)
              .help(remoteAuthority)
              .accessibilityLabel("Remote server \(remoteAuthority)")
          }
        }
        Text(remoteAuthority.map { "\($0):\(rootPath)" } ?? rootPath)
          .font(.caption)
          .foregroundStyle(.tertiary)
          .lineLimit(1)
          .truncationMode(.middle)
      }
      Spacer(minLength: 8)
      Button {
        showingFailure.toggle()
      } label: {
        // 22x22 hit target, matching the "+" / "..." affordances on a
        // healthy Project header so the trailing edge lines up.
        Image(systemName: "exclamationmark.triangle.fill")
          .font(.system(size: 11, weight: .medium))
          .frame(width: 22, height: 22)
          .contentShape(Circle())
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

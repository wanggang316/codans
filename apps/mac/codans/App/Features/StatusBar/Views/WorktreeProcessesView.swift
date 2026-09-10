import CodansCore
import SwiftUI

/// Fixed-size presentation avoids animated NSPopover resizing during process
/// exits. See the 2026-08-20 Agents View popover crash write-up.
struct WorktreeProcessesView: View {
  let entries: [WorktreeProcessEntry]
  let onSelect: (WorktreeProcessEntry) -> Void

  @State private var isPresented = false
  @State private var isPinned = false
  @State private var isBadgeHovered = false
  @State private var isPopoverHovered = false
  @State private var visibleRows = 1
  @State private var hoverTask: Task<Void, Never>?

  var body: some View {
    Button {
      if isPresented {
        dismiss()
      } else {
        present(pinned: true)
      }
    } label: {
      HStack(spacing: 5) {
        Image(systemName: "terminal")
          .accessibilityHidden(true)
        Text(entries.count.formatted())
          .monospacedDigit()
      }
      .font(.system(size: 12, weight: .medium))
      .foregroundStyle(entries.isEmpty ? .secondary : .primary)
      .padding(.horizontal, 6)
      .frame(minHeight: 28)
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .help("Show worktree processes")
    .accessibilityLabel("Worktree processes")
    .accessibilityValue("\(entries.count) running")
    .accessibilityIdentifier("status.processes")
    .onHover { hovering in
      isBadgeHovered = hovering
      reconcileHover()
    }
    .popover(isPresented: $isPresented, arrowEdge: .bottom) {
      WorktreeProcessListView(entries: entries, visibleRows: visibleRows) { entry in
        dismiss()
        // Focus tears down terminal surfaces. Leave the popover's
        // dismissal transaction before starting that cascade.
        DispatchQueue.main.async { onSelect(entry) }
      }
      .onHover { hovering in
        isPopoverHovered = hovering
        reconcileHover()
      }
      .onExitCommand { dismiss() }
    }
    .onChange(of: isPresented) { _, presented in
      if !presented {
        hoverTask?.cancel()
        isPinned = false
        isPopoverHovered = false
      }
    }
    .onDisappear {
      dismiss()
      isBadgeHovered = false
      isPopoverHovered = false
    }
  }

  private func present(pinned: Bool) {
    hoverTask?.cancel()
    visibleRows = min(max(entries.count, 1), 8)
    isPinned = pinned
    isPresented = true
  }

  private func dismiss() {
    hoverTask?.cancel()
    isPresented = false
    isPinned = false
  }

  private func reconcileHover() {
    hoverTask?.cancel()
    guard !isPinned else { return }
    let shouldShow = isBadgeHovered || isPopoverHovered
    guard shouldShow != isPresented else { return }
    hoverTask = Task { @MainActor in
      try? await Task.sleep(for: .milliseconds(200))
      guard !Task.isCancelled else { return }
      if shouldShow {
        present(pinned: false)
      } else {
        dismiss()
      }
    }
  }
}

struct WorktreeProcessListView: View {
  let entries: [WorktreeProcessEntry]
  let visibleRows: Int
  let onSelect: (WorktreeProcessEntry) -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      Text("Processes")
        .font(.system(size: 13, weight: .semibold))
        .foregroundStyle(.secondary)
      ScrollView {
        if entries.isEmpty {
          Text("No running processes")
            .font(.callout)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, minHeight: 34, alignment: .leading)
        } else {
          LazyVStack(spacing: 0) {
            ForEach(entries) { entry in
              WorktreeProcessRow(entry: entry) { onSelect(entry) }
            }
          }
        }
      }
      .frame(height: CGFloat(visibleRows) * 34)
    }
    .padding(14)
    .frame(width: 370)
    .transaction { $0.animation = nil }
    .accessibilityIdentifier("status.processes.popover")
  }
}

private struct WorktreeProcessRow: View {
  let entry: WorktreeProcessEntry
  let onSelect: () -> Void
  @State private var isHovered = false

  var body: some View {
    Button(action: onSelect) {
      HStack(spacing: 8) {
        Circle()
          .fill(.green)
          .frame(width: 7, height: 7)
          .accessibilityHidden(true)
        WorktreeProcessIconView(entry: entry)
        Text(entry.name)
          .font(.system(size: 13, weight: .medium))
          .lineLimit(1)
          .truncationMode(.middle)
        Text(String(entry.pid))
          .font(.system(size: 11).monospacedDigit())
          .foregroundStyle(.secondary)
          .fixedSize()
        Spacer(minLength: 8)
        TimelineView(.periodic(from: .now, by: 1)) { context in
          Text(WorktreeProcessDuration.label(startedAt: entry.startedAt, now: context.date))
            .font(.system(size: 11).monospacedDigit())
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .frame(width: 68, alignment: .trailing)
        }
      }
      .padding(.horizontal, 6)
      .frame(height: 34)
      .contentShape(Rectangle())
      .background(isHovered ? Color.primary.opacity(0.06) : .clear, in: .rect(cornerRadius: 5))
    }
    .buttonStyle(.plain)
    .onHover { isHovered = $0 }
    .help("Show \(entry.name) in its terminal")
    .accessibilityLabel("\(entry.name), running, process \(entry.pid)")
    .accessibilityHint("Switch to the owning tab and terminal pane")
    .accessibilityIdentifier("status.processes.row.\(entry.paneID.raw.uuidString)")
  }
}

enum WorktreeProcessDuration {
  static func label(startedAt: Date?, now: Date) -> String {
    guard let startedAt else { return "—" }
    let seconds = max(0, Int(now.timeIntervalSince(startedAt)))
    if seconds < 60 { return "\(seconds)s" }
    let minutes = seconds / 60
    if minutes < 60 { return "\(minutes)m" }
    let hours = minutes / 60
    if hours < 100 { return "\(hours)h \(minutes % 60)m" }
    return "\(hours / 24)d \(hours % 24)h"
  }
}

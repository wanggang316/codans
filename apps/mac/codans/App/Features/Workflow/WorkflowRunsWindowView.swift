import AppKit
import CodansCore
import SwiftUI

/// The Workflow Runs window: every run — the engine's live ones first, then
/// the history each local worktree keeps on disk — on the left, and the
/// selected run's steps, attention actions, log and deliveries on the right.
/// Opened from the toolbar's workflow group; it stays open beside the main
/// window and follows a live run as it goes.
struct WorkflowRunsWindowView: View {
  @Environment(\.workflowEngine) private var engine
  @Environment(HierarchyManager.self) private var hierarchy
  @Environment(WorkflowRunsNavigator.self) private var navigator

  @State private var history: [WorkflowRunSummary] = []
  @State private var selection: UUID?

  private var liveRuns: [WorkflowRunSession] { engine?.activeRuns ?? [] }
  private var liveIDs: Set<UUID> { Set(liveRuns.map(\.id)) }
  private var pastRuns: [WorkflowRunSummary] { history.filter { !liveIDs.contains($0.id) } }

  private var localWorktrees: [(name: String, path: String)] {
    hierarchy.catalog.projects
      .filter { $0.remoteHost == nil }
      .flatMap { project in project.worktrees.filter { !$0.archived }.map { (name: $0.name, path: $0.path) } }
  }

  var body: some View {
    NavigationSplitView {
      List(selection: $selection) {
        if !liveRuns.isEmpty {
          Section("Running") {
            ForEach(liveRuns, id: \.id) { session in
              runRow(
                name: session.name, worktree: session.run.configuration.source.worktreeName,
                status: session.attention == nil ? "running" : "needs attention",
                needsAttention: session.attention != nil, isLive: true, date: session.run.configuration.startedAt
              )
              .tag(session.id)
            }
          }
        }
        Section("History") {
          if pastRuns.isEmpty {
            Text("No finished runs yet.")
              .foregroundStyle(.secondary)
          }
          ForEach(pastRuns) { summary in
            runRow(
              name: summary.name, worktree: summary.worktreeName,
              status: summary.status.replacingOccurrences(of: "_", with: " "),
              needsAttention: false, isLive: false, date: summary.startedAt
            )
            .tag(summary.id)
          }
        }
      }
      .navigationSplitViewColumnWidth(min: 240, ideal: 280, max: 360)
      .toolbar {
        ToolbarItem {
          Button {
            reloadHistory()
          } label: {
            Label("Refresh", systemImage: "arrow.clockwise")
          }
          .help("Reload run history from disk")
        }
      }
    } detail: {
      detail
    }
    .navigationTitle("Workflow Runs")
    .onAppear {
      reloadHistory()
      applyRequest()
    }
    .onChange(of: navigator.requestedWorktreePath) { applyRequest() }
    // A run that finishes moves from Running to History; re-read the index.
    .onChange(of: liveIDs) { reloadHistory() }
  }

  // MARK: - Sidebar

  private func runRow(
    name: String, worktree: String, status: String, needsAttention: Bool, isLive: Bool, date: Date
  ) -> some View {
    HStack(spacing: 8) {
      Group {
        if needsAttention {
          Image(systemName: "exclamationmark.circle.fill").foregroundStyle(.orange)
            .accessibilityLabel("Needs attention")
        } else if isLive {
          ProgressView().controlSize(.small)
        } else {
          Image(systemName: "arrow.triangle.branch").foregroundStyle(.secondary)
            .accessibilityHidden(true)
        }
      }
      .frame(width: 16)
      VStack(alignment: .leading, spacing: 2) {
        Text(name).lineLimit(1)
        Text("\(worktree) · \(status)")
          .font(.caption)
          .foregroundStyle(.secondary)
          .lineLimit(1)
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      Text(date, format: .relative(presentation: .numeric, unitsStyle: .abbreviated))
        .font(.caption)
        .foregroundStyle(.tertiary)
        .lineLimit(1)
        .fixedSize()
    }
    .padding(.vertical, 2)
  }

  // MARK: - Detail

  @ViewBuilder
  private var detail: some View {
    if let selection, let engine, let session = liveRuns.first(where: { $0.id == selection }) {
      WorkflowRunDetailView(content: .live(session, engine))
        .id(selection)
    } else if let selection, let summary = history.first(where: { $0.id == selection }) {
      WorkflowRunDetailView(content: .past(summary))
        .id(selection)
    } else {
      ContentUnavailableView(
        "No Run Selected", systemImage: "arrow.triangle.branch",
        description: Text("Pick a run on the left to see its steps and log."))
    }
  }

  // MARK: - Loading

  private func reloadHistory() {
    let worktrees = localWorktrees
    Task {
      let loaded = await Task.detached(priority: .userInitiated) {
        WorkflowRunHistory.load(worktrees: worktrees)
      }.value
      history = loaded
      if selection == nil { selection = liveRuns.first?.id ?? loaded.first?.id }
    }
  }

  /// Opened for a worktree: its live run if there is one, else its newest.
  private func applyRequest() {
    guard let path = navigator.consumeRequest() else { return }
    if let live = liveRuns.first(where: { $0.run.configuration.source.worktreePath == path }) {
      selection = live.id
    } else if let past = history.first(where: { $0.worktreePath == path }) {
      selection = past.id
    }
  }
}

/// The right side of the Workflow Runs window for one run.
struct WorkflowRunDetailView: View {
  enum Content {
    case live(WorkflowRunSession, WorkflowEngine)
    case past(WorkflowRunSummary)
  }

  let content: Content

  @State private var pastSteps: [WorkflowRunDisplay.StepRow] = []
  @State private var deliveries: [URL] = []

  private var runDirectory: URL {
    switch content {
    case .live(let session, _): return session.store.runDirectory
    case .past(let summary): return summary.runDirectory
    }
  }

  private var steps: [WorkflowRunDisplay.StepRow] {
    switch content {
    case .live(let session, _): return WorkflowRunDisplay.stepRows(for: session.run)
    case .past: return pastSteps
    }
  }

  private var isLive: Bool {
    if case .live = content { return true }
    return false
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      header
        .padding(16)
      Divider()
      HStack(spacing: 0) {
        ScrollView {
          VStack(alignment: .leading, spacing: 16) {
            if case .live(let session, let engine) = content, let attention = session.attention {
              GroupBox {
                WorkflowAttentionView(session: session, engine: engine, attention: attention, layout: .row)
                  .frame(maxWidth: .infinity, alignment: .leading)
              } label: {
                Label("Needs your attention", systemImage: "exclamationmark.circle.fill")
                  .foregroundStyle(.orange)
              }
            }
            stepsSection
            deliveriesSection
          }
          .padding(16)
          .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(width: 300)
        Divider()
        VStack(alignment: .leading, spacing: 0) {
          Text("Log")
            .font(.headline)
            .padding(.horizontal, 12)
            .padding(.top, 12)
          WorkflowRunLogView(logURL: WorkflowRunLayout.logURL(runDirectory: runDirectory), isLive: isLive)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
      }
    }
    .task(id: runDirectory) { await loadFiles() }
  }

  // MARK: - Header

  private var header: some View {
    HStack(alignment: .firstTextBaseline) {
      VStack(alignment: .leading, spacing: 4) {
        switch content {
        case .live(let session, _):
          Text(session.name).font(.title3.weight(.semibold))
          TimelineView(.periodic(from: .now, by: 1)) { context in
            Text(
              "\(session.run.configuration.source.worktreeName) · \(session.attention == nil ? "running" : "needs attention") · \(Self.duration(session.elapsed(at: context.date)))"
            )
            .foregroundStyle(.secondary)
          }
        case .past(let summary):
          Text(summary.name).font(.title3.weight(.semibold))
          Text(
            "\(summary.worktreeName) · \(summary.status.replacingOccurrences(of: "_", with: " ")) · \(summary.startedAt.formatted(date: .abbreviated, time: .shortened))"
          )
          .foregroundStyle(.secondary)
        }
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      Button("Reveal Run Folder") {
        NSWorkspace.shared.activateFileViewerSelecting([runDirectory])
      }
      if case .live(let session, let engine) = content, !session.run.status.isTerminal {
        Button("Cancel Run", role: .destructive) {
          engine.cancel(runID: session.id)
        }
      }
    }
  }

  static func duration(_ interval: TimeInterval) -> String {
    let seconds = Int(interval)
    return seconds >= 3600
      ? String(format: "%d:%02d:%02d", seconds / 3600, seconds / 60 % 60, seconds % 60)
      : String(format: "%d:%02d", seconds / 60, seconds % 60)
  }

  // MARK: - Steps

  private var stepsSection: some View {
    VStack(alignment: .leading, spacing: 8) {
      Text("Steps").font(.headline)
      if steps.isEmpty {
        Text("No step record.").foregroundStyle(.secondary)
      }
      ForEach(steps) { row in
        HStack(spacing: 8) {
          stepGlyph(row.status)
            .frame(width: 16)
          Text(row.name)
            .foregroundStyle(row.status == .pending ? .secondary : .primary)
        }
      }
    }
  }

  @ViewBuilder
  private func stepGlyph(_ status: WorkflowRunDisplay.StepStatus) -> some View {
    switch status {
    case .done:
      Image(systemName: "checkmark.circle.fill").foregroundStyle(.green).accessibilityLabel("Done")
    case .current:
      Image(systemName: "circle.dotted.circle.fill").foregroundStyle(.blue).accessibilityLabel("Current")
    case .pending:
      Image(systemName: "circle").foregroundStyle(.tertiary).accessibilityLabel("Pending")
    case .skipped:
      Image(systemName: "arrow.uturn.right.circle").foregroundStyle(.secondary).accessibilityLabel("Skipped")
    case .failed:
      Image(systemName: "xmark.circle.fill").foregroundStyle(.red).accessibilityLabel("Failed")
    }
  }

  // MARK: - Deliveries

  @ViewBuilder
  private var deliveriesSection: some View {
    VStack(alignment: .leading, spacing: 6) {
      Text("Deliveries").font(.headline)
      if deliveries.isEmpty {
        Text("None yet.").foregroundStyle(.secondary)
      }
      ForEach(deliveries, id: \.self) { url in
        Button {
          NSWorkspace.shared.open(url)
        } label: {
          Label(url.lastPathComponent, systemImage: "doc.text")
        }
        .buttonStyle(.link)
      }
    }
  }

  private func loadFiles() async {
    let directory = runDirectory
    let live = isLive
    repeat {
      let (steps, files) = await Task.detached(priority: .utility) {
        (
          live ? [] : WorkflowRunHistory.stepRows(runDirectory: directory),
          WorkflowRunHistory.deliveries(runDirectory: directory)
        )
      }.value
      if !live { pastSteps = steps }
      if files != deliveries { deliveries = files }
      guard live else { return }
      try? await Task.sleep(for: .seconds(2))
    } while !Task.isCancelled
  }
}

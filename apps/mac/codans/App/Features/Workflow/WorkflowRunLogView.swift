import Foundation
import SwiftUI

/// A run's `log.md` as a time-stamped list. A live run is followed: the
/// file is re-read when it changes and the view stays pinned to the newest
/// line unless the reader has scrolled away.
struct WorkflowRunLogView: View {
  let logURL: URL
  let isLive: Bool

  @State private var lines: [Line] = []
  @State private var modifiedAt: Date?

  nonisolated struct Line: Identifiable, Equatable, Sendable {
    let id: Int
    let time: Date?
    let text: String
  }

  var body: some View {
    ScrollViewReader { proxy in
      ScrollView {
        LazyVStack(alignment: .leading, spacing: 3) {
          if lines.isEmpty {
            Text("Nothing logged yet.")
              .foregroundStyle(.secondary)
          }
          ForEach(lines) { line in
            HStack(alignment: .firstTextBaseline, spacing: 10) {
              Text(line.time.map { Self.timeFormat.string(from: $0) } ?? "")
                .foregroundStyle(.secondary)
                .frame(width: 64, alignment: .leading)
              Text(line.text)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .font(.callout.monospaced())
            .id(line.id)
          }
        }
        .textSelection(.enabled)
        .padding(10)
      }
      .onChange(of: lines.count) {
        guard isLive, let last = lines.last else { return }
        withAnimation(.easeOut(duration: 0.15)) { proxy.scrollTo(last.id, anchor: .bottom) }
      }
    }
    .task(id: logURL) { await follow() }
  }

  private func follow() async {
    lines = []
    modifiedAt = nil
    repeat {
      reloadIfChanged()
      guard isLive else { return }
      try? await Task.sleep(for: .seconds(1))
    } while !Task.isCancelled
  }

  private func reloadIfChanged() {
    let path = logURL.path(percentEncoded: false)
    let stamp = (try? FileManager.default.attributesOfItem(atPath: path))?[.modificationDate] as? Date
    guard stamp != modifiedAt else { return }
    modifiedAt = stamp
    guard let text = try? String(contentsOf: logURL, encoding: .utf8) else { return }
    lines = Self.parse(text)
  }

  /// `- [2026-09-23T13:04:25Z] step ask: launching advisor` → time + text;
  /// headings and blank lines are dropped, anything else is kept as is.
  nonisolated static func parse(_ text: String) -> [Line] {
    var result: [Line] = []
    for raw in text.split(separator: "\n", omittingEmptySubsequences: true) {
      let line = String(raw)
      if line.hasPrefix("#") { continue }
      if line.hasPrefix("- ["), let close = line.firstIndex(of: "]") {
        let stamp = String(line[line.index(line.startIndex, offsetBy: 3)..<close])
        let rest = line[line.index(after: close)...].trimmingCharacters(in: .whitespaces)
        result.append(Line(id: result.count, time: isoFormat.date(from: stamp), text: rest))
      } else {
        result.append(Line(id: result.count, time: nil, text: line))
      }
    }
    return result
  }

  nonisolated(unsafe) private static let isoFormat = ISO8601DateFormatter()
  private static let timeFormat: DateFormatter = {
    let formatter = DateFormatter()
    formatter.dateFormat = "HH:mm:ss"
    return formatter
  }()
}

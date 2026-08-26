import CodansCore
import ComposableArchitecture
import SwiftUI

/// Settings window sidebar. Fixed-order global sections at the top, then the open
/// Projects grouped by where they live: a "Local" section for on-disk projects and one
/// section per server host (titled with its hostname / IP). With no Server projects the
/// single group keeps the plain "Projects" title. Each project row is a
/// `DisclosureGroup` exposing the Project's `General` and `Commands` sub-rows.
///
/// The Project list comes from the live `HierarchyManager` catalog; adding or removing a
/// Project in the main window reflects here without any explicit refresh (@Observable
/// subscription).
///
/// Disclosure open/close state lives in a local `@State` dictionary so Projects keep their
/// expansion across sidebar selection changes. This state is intentionally *not* persisted —
/// closing the window drops session state.
struct SettingsSidebarView: View {
  @Binding var selection: SettingsSection?
  @Environment(HierarchyManager.self) private var hierarchyManager
  @State private var expandedProjects: [ProjectID: Bool] = [:]

  var body: some View {
    ScrollViewReader { proxy in
      List(selection: $selection) {
        Section {
          ForEach(SettingsSection.globals, id: \.self) { section in
            globalRow(for: section)
              .tag(Optional(section))
              .id(section)
          }
        }

        let groups = projectGroups(in: hierarchyManager.catalog)
        if groups.isEmpty {
          Section("Projects") {
            Text("No open projects")
              .font(.caption)
              .foregroundStyle(.tertiary)
          }
        } else {
          ForEach(groups, id: \.title) { group in
            Section(group.title) {
              ForEach(group.projects) { project in
                projectDisclosure(project: project)
              }
            }
          }
        }
      }
      .listStyle(.sidebar)
      .navigationSplitViewColumnWidth(min: 180, ideal: 200)
      // Whenever the selection lands on a Project sub-row — including the
      // initial render when the window is opened via "Project Settings…" —
      // expand that Project's disclosure so the selected child is visible
      // and scroll the row into view. Sibling Projects keep whatever
      // expansion the user set previously. The scroll is deferred to the
      // next runloop tick so the disclosure expansion has been applied to
      // the layout tree before `scrollTo` runs — scrolling to a row that
      // is still inside a collapsed `DisclosureGroup` is a no-op.
      .onChange(of: selection, initial: true) { _, newValue in
        guard let section = newValue else { return }
        if let pid = section.projectID {
          expandedProjects[pid] = true
        }
        Task { @MainActor in
          proxy.scrollTo(section, anchor: .center)
        }
      }
    }
  }

  // MARK: - Rows

  @ViewBuilder
  private func projectDisclosure(project: Project) -> some View {
    let binding = Binding<Bool>(
      get: { expandedProjects[project.id] ?? false },
      set: { expandedProjects[project.id] = $0 }
    )
    let subrows = SettingsSection.subrows(for: project.kind, projectID: project.id)
    DisclosureGroup(isExpanded: binding) {
      ForEach(subrows, id: \.self) { subrow in
        Label(subrow.projectSubrowTitle ?? "", systemImage: subrowIcon(for: subrow))
          .tag(Optional(subrow))
          .id(subrow)
      }
    } label: {
      // A tap on the Project name selects its General pane when the disclosure is
      // currently collapsed (and expand it to reveal the sub-rows). `simultaneousGesture`
      // runs alongside DisclosureGroup's built-in label tap so the expansion toggle still
      // happens — we only add the selection write.
      Label(project.name, systemImage: "folder")
        .contentShape(Rectangle())
        .accessibilityAddTraits(.isButton)
        .simultaneousGesture(
          TapGesture().onEnded {
            if !(expandedProjects[project.id] ?? false) {
              selection = .projectGeneral(project.id)
            }
          }
        )
    }
  }

  // MARK: - Helpers

  private func sortedProjects(in catalog: Catalog) -> [Project] {
    catalog.projects
      .sorted { lhs, rhs in
        lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
      }
  }

  private struct ProjectGroup {
    let title: String
    let projects: [Project]
  }

  /// Group the open projects by where they live. Local projects come first;
  /// server hosts follow alphabetically, titled by hostname / IP (the address
  /// alone — user and port stay out of the section header). A catalog with no
  /// Server projects keeps the familiar single "Projects" title.
  private func projectGroups(in catalog: Catalog) -> [ProjectGroup] {
    let sorted = sortedProjects(in: catalog)
    let locals = sorted.filter { $0.remoteHost == nil }
    let servers = sorted.filter { $0.remoteHost != nil }
    guard !servers.isEmpty else {
      return locals.isEmpty ? [] : [ProjectGroup(title: "Projects", projects: locals)]
    }
    var groups: [ProjectGroup] = []
    if !locals.isEmpty {
      groups.append(ProjectGroup(title: "Local", projects: locals))
    }
    let byHost = Dictionary(grouping: servers) { $0.remoteHost?.alias ?? "" }
    for alias in byHost.keys.sorted(by: {
      $0.localizedCaseInsensitiveCompare($1) == .orderedAscending
    }) {
      groups.append(ProjectGroup(title: alias, projects: byHost[alias] ?? []))
    }
    return groups
  }

  /// Per-section sidebar row. GitHub and Worktrees both render their leading
  /// icon from a bundled SVG asset (template-rendered) so the dropdown picker
  /// stays visually consistent with the rest of the app's Worktree affordances
  /// (the sidebar `WorktreeRowIcon` reuses the same `git-branch` asset).
  @ViewBuilder
  private func globalRow(for section: SettingsSection) -> some View {
    let title = section.globalTitle ?? ""
    if let assetName = assetIcon(for: section) {
      Label {
        Text(title)
      } icon: {
        Image(assetName)
          .renderingMode(.template)
          .resizable()
          .aspectRatio(contentMode: .fit)
          .frame(width: 16, height: 16)
      }
    } else {
      Label(title, systemImage: icon(for: section))
    }
  }

  /// Sections whose leading icon comes from a bundled SVG asset instead of an
  /// SF Symbol.
  private func assetIcon(for section: SettingsSection) -> String? {
    switch section {
    case .github: return "github"
    case .worktree: return "git-branch"
    default: return nil
    }
  }

  private func icon(for section: SettingsSection) -> String {
    switch section {
    case .general: return "gearshape"
    case .globalCommands: return "terminal"
    case .agents: return "sparkles"
    case .github: return "arrow.triangle.pull"
    case .worktree: return "square.dashed"
    case .terminal: return "terminal"
    case .notifications: return "bell"
    case .developer: return "hammer"
    case .shortcuts: return "command"
    case .updates: return "arrow.down.circle"
    case .about: return "info.circle"
    case .projectGeneral, .projectScripts:
      return ""
    }
  }

  /// Leading icon for Project sub-rows. Matches the global-section icon language where
  /// intuitive (Commands → terminal) and drops to a blank for rows whose
  /// icon would add noise rather than signal.
  private func subrowIcon(for section: SettingsSection) -> String {
    switch section {
    case .projectGeneral: return "slider.horizontal.3"
    case .projectScripts: return "terminal"
    default: return ""
    }
  }
}

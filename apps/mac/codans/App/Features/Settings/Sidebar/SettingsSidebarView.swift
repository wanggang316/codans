import CodansCore
import ComposableArchitecture
import SwiftUI

/// Settings window sidebar. Fixed-order global sections at the top, then the open
/// Projects grouped by where they live: a "Local" section for on-disk projects and one
/// section per server host (titled with its hostname / IP). With no Remote Projects the
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

  /// The sidebar List is an outline (the Project rows disclose), so it indents every
  /// top-level row by the disclosure-triangle width, leaf rows too. The global rows
  /// have no triangle; pull them back so their icons start at the section-header and
  /// disclosure-triangle edge.
  private static let outlineIndent: CGFloat = 12

  var body: some View {
    ScrollViewReader { proxy in
      List(selection: $selection) {
        ForEach(SettingsSection.globalGroups, id: \.self) { group in
          Section {
            ForEach(group, id: \.self) { section in
              globalRow(for: section)
                .padding(.leading, -Self.outlineIndent)
                .tag(Optional(section))
                .id(section)
            }
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
      // The Project's own icon, not a hardcoded `folder`, so a re-iconed
      // Project is recognizable here too and the row lines up with the
      // glyph-bearing global rows above it.
      Label {
        Text(project.name)
      } icon: {
        ProjectIconView(
          icon: project.icon, color: project.color,
          defaultSymbol: ProjectIconView.defaultSymbol(for: project.kind)
        )
      }
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
  /// Remote Projects keeps the familiar single "Projects" title.
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

  /// Global sidebar row: the title with a colored icon tile, in the style of
  /// System Settings. Project rows keep their own Project icons.
  private func globalRow(for section: SettingsSection) -> some View {
    Label {
      Text(section.globalTitle ?? "")
    } icon: {
      SettingsIconTile(style: iconStyle(for: section))
    }
  }

  private func iconStyle(for section: SettingsSection) -> SettingsIconTile.Style {
    switch section {
    case .general: return .init(.symbol("gearshape.fill"), .gray)
    case .gitPlatforms: return .init(.symbol("externaldrive.badge.timemachine"), .indigo)
    case .worktree: return .init(.asset("git-branch"), .orange)
    case .terminal: return .init(.prompt, .black, glyph: .green)
    case .notifications: return .init(.symbol("bell.badge.fill"), .red)
    case .globalCommands: return .init(.symbol("play.fill"), .green, glyphSize: 10)
    case .shortcuts: return .init(.symbol("command"), .gray)
    case .updates: return .init(.symbol("arrow.down"), .blue)
    case .about: return .init(.symbol("info"), .gray)
    case .agents: return .init(.symbol("sparkles"), .orange, gradientEnd: .pink)
    case .developer: return .init(.symbol("puzzlepiece.extension.fill"), .pink, gradientEnd: .purple)
    // Matches the AgentState panel's "Workflows" run rows (`WorkflowRunsSection`)
    // so the glyph reads the same wherever a run shows up.
    case .workflows: return .init(.symbol("arrow.triangle.branch"), .teal)
    case .hosts: return .init(.symbol("globe"), .purple)
    case .projectGeneral, .projectScripts: return .init(.symbol("questionmark"), .gray)
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

/// A rounded-square tile with a white glyph on a gradient fill, as System
/// Settings draws its sidebar icons. The fill is the tile color's system
/// gradient; `gradientEnd` gives a two-color tile.
private struct SettingsIconTile: View {
  enum Glyph {
    case symbol(String)
    /// A shell prompt, `>_`. SF Symbols draws it only inside a window frame.
    case prompt
    /// A template-rendered SVG in the asset catalog.
    case asset(String)
  }

  struct Style {
    let glyph: Glyph
    let color: Color
    var gradientEnd: Color?
    var glyphColor: Color = .white
    /// A solid glyph (a filled triangle) reads larger than an outlined one
    /// of the same size, so it can ask for a smaller box.
    var glyphSize: CGFloat = SettingsIconTile.defaultGlyphSize

    init(
      _ glyph: Glyph, _ color: Color, gradientEnd: Color? = nil, glyph glyphColor: Color = .white,
      glyphSize: CGFloat = SettingsIconTile.defaultGlyphSize
    ) {
      self.glyph = glyph
      self.color = color
      self.gradientEnd = gradientEnd
      self.glyphColor = glyphColor
      self.glyphSize = glyphSize
    }
  }

  let style: Style

  private static let side: CGFloat = 20
  private static let cornerRadius: CGFloat = 5
  static let defaultGlyphSize: CGFloat = 12
  /// Lets a wide symbol (a drive with a badge) grow past its glyph size so it
  /// does not read smaller than the square ones.
  private static let wideGlyphExtra: CGFloat = 2

  var body: some View {
    RoundedRectangle(cornerRadius: Self.cornerRadius, style: .continuous)
      .fill(fill)
      .overlay {
        RoundedRectangle(cornerRadius: Self.cornerRadius, style: .continuous)
          .strokeBorder(.white.opacity(0.12), lineWidth: 0.5)
      }
      .overlay { glyph.foregroundStyle(style.glyphColor) }
      .frame(width: Self.side, height: Self.side)
  }

  private var fill: AnyShapeStyle {
    if let end = style.gradientEnd {
      return AnyShapeStyle(
        LinearGradient(colors: [style.color, end], startPoint: .topLeading, endPoint: .bottomTrailing))
    }
    return AnyShapeStyle(style.color.gradient)
  }

  @ViewBuilder
  private var glyph: some View {
    switch style.glyph {
    // Fit every glyph in the same box: the sidebar Label scales a bare
    // symbol up to its row icon size, which fills the tile.
    case .symbol(let name):
      Image(systemName: name)
        .resizable()
        .fontWeight(.semibold)
        .symbolRenderingMode(.monochrome)
        .scaledToFit()
        .frame(width: style.glyphSize + Self.wideGlyphExtra, height: style.glyphSize)
    case .prompt:
      Text(">_")
        .font(.system(size: 10, weight: .heavy, design: .monospaced))
        .fixedSize()
    case .asset(let name):
      Image(name)
        .renderingMode(.template)
        .resizable()
        .scaledToFit()
        .frame(width: style.glyphSize, height: style.glyphSize)
    }
  }
}

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
    case .general: return .init(.symbol("gearshape.fill", size: 12), .gray)
    // The badge sits low left, so the glyph moves right a little to look centered.
    case .gitPlatforms:
      return .init(.symbol("externaldrive.badge.timemachine", size: 16, nudge: .init(width: -0.5, height: 0)), .indigo)
    case .worktree: return .init(.asset("git-branch", size: 12), .orange)
    case .terminal: return .init(.prompt, .graphite, glyphColor: SettingsIconTile.promptGreen)
    // The badge widens the box upward, which leaves the bell low; lift it.
    case .notifications:
      return .init(.symbol("bell.badge.fill", size: 12, nudge: .init(width: 0, height: -0.5)), .red)
    // A triangle's mass sits left of its box center; shift it right.
    case .globalCommands: return .init(.symbol("play.fill", size: 10, nudge: .init(width: 0.5, height: 0)), .green)
    case .shortcuts: return .init(.symbol("command", size: 12), .gray)
    case .updates: return .init(.symbol("arrow.down", size: 12), .blue)
    case .about: return .init(.symbol("info", size: 12), .gray)
    case .agents: return .init(.symbol("sparkles", size: 12), .sunset)
    // The tab on the right pulls the mass left of the box center.
    case .developer:
      return .init(.symbol("puzzlepiece.extension.fill", size: 14, nudge: .init(width: 0.5, height: 0)), .magenta)
    case .workflows: return .init(.symbol("app.connected.to.app.below.fill", size: 12), .teal)
    case .hosts: return .init(.symbol("globe", size: 12), .purple)
    case .projectGeneral, .projectScripts: return .init(.symbol("questionmark", size: 12), .gray)
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

/// A rounded-square tile with a glyph on a vertical gradient, as System
/// Settings draws its sidebar icons. Each symbol is fit in a box sized for its
/// shape, so glyphs of different proportions read at the same weight.
private struct SettingsIconTile: View {
  enum Glyph {
    /// An SF Symbol fit in a `size`-point box, moved by `nudge` points when
    /// its visual mass is off its box center. Keep `size` even and `nudge` a
    /// multiple of 0.5 so the glyph lands on the pixel grid: an odd size
    /// centers the box on a half point, and the glyph renders a pixel low.
    case symbol(String, size: CGFloat, nudge: CGSize = .zero)
    /// A shell prompt, `>_`. SF Symbols draws it only inside a window frame.
    case prompt
    /// A template-rendered SVG in the asset catalog.
    case asset(String, size: CGFloat)
  }

  /// The two stops of the tile fill, top to bottom unless `diagonal`, which
  /// runs from the top-left corner to the bottom-right one.
  struct Palette {
    let top: Color
    let bottom: Color
    var diagonal = false

    init(_ top: UInt32, _ bottom: UInt32, diagonal: Bool = false, space: Color.RGBColorSpace = .sRGB) {
      self.top = Color(rgb: top, space: space)
      self.bottom = Color(rgb: bottom, space: space)
      self.diagonal = diagonal
    }

    static let gray = Palette(0xA1A1A6, 0x6E6E73)
    static let indigo = Palette(0x8E8CF8, 0x5856D6)
    static let orange = Palette(0xFFB443, 0xFF8A00)
    static let graphite = Palette(0x48484A, 0x1C1C1E)
    static let red = Palette(0xFF6B6B, 0xF02D3A)
    static let green = Palette(0x5EDB7A, 0x28B446)
    static let blue = Palette(0x4DA3FF, 0x0A6CFF)
    /// Display P3: the pink-to-amber of a vivid app icon lies outside sRGB.
    static let sunset = Palette(0xE22FE4, 0xFFC03C, diagonal: true, space: .displayP3)
    static let magenta = Palette(0xF06BD0, 0xA53BF0)
    static let teal = Palette(0x4FD8E0, 0x12A5B8)
    static let purple = Palette(0xB57BFF, 0x8A3FFC)
  }

  struct Style {
    let glyph: Glyph
    let palette: Palette
    var glyphColor: Color = .white

    init(_ glyph: Glyph, _ palette: Palette, glyphColor: Color = .white) {
      self.glyph = glyph
      self.palette = palette
      self.glyphColor = glyphColor
    }
  }

  static let promptGreen = Color(rgb: 0x4CE07A)

  let style: Style

  private static let side: CGFloat = 20
  private static let cornerRadius: CGFloat = 4.75

  var body: some View {
    let shape = RoundedRectangle(cornerRadius: Self.cornerRadius, style: .continuous)
    shape
      .fill(
        LinearGradient(
          colors: [style.palette.top, style.palette.bottom],
          startPoint: style.palette.diagonal ? .topLeading : .top,
          endPoint: style.palette.diagonal ? .bottomTrailing : .bottom
        )
      )
      .overlay {
        // A light inner edge, brighter at the top, gives the tile its lift.
        shape.strokeBorder(
          LinearGradient(colors: [.white.opacity(0.28), .white.opacity(0.06)], startPoint: .top, endPoint: .bottom),
          lineWidth: 0.5
        )
      }
      .overlay {
        glyph
          .foregroundStyle(style.glyphColor)
          .shadow(color: .black.opacity(0.18), radius: 0.5)
      }
      .frame(width: Self.side, height: Self.side)
      .shadow(color: .black.opacity(0.22), radius: 0.6, y: 0.5)
  }

  @ViewBuilder
  private var glyph: some View {
    switch style.glyph {
    // `resizable()` fits the glyph's own bounds in the box; a font-sized symbol
    // keeps uneven side bearings and the sidebar Label scales it up.
    case .symbol(let name, let size, let nudge):
      Image(systemName: name)
        .resizable()
        .fontWeight(.semibold)
        .scaledToFit()
        .frame(width: size, height: size)
        .offset(nudge)
    case .prompt:
      PromptShape()
        .stroke(style: StrokeStyle(lineWidth: 1.6, lineCap: .round, lineJoin: .round))
        .frame(width: 9, height: 7.5)
    case .asset(let name, let size):
      Image(name)
        .renderingMode(.template)
        .resizable()
        .scaledToFit()
        .frame(width: size, height: size)
    }
  }
}

/// `>_` drawn as strokes so it centers on its own bounds, unlike text, which
/// sits on a baseline.
nonisolated private struct PromptShape: Shape {
  func path(in rect: CGRect) -> Path {
    var path = Path()
    path.move(to: CGPoint(x: rect.minX, y: rect.minY))
    path.addLine(to: CGPoint(x: rect.minX + rect.width * 0.38, y: rect.minY + rect.height * 0.42))
    path.addLine(to: CGPoint(x: rect.minX, y: rect.minY + rect.height * 0.84))
    path.move(to: CGPoint(x: rect.minX + rect.width * 0.55, y: rect.maxY))
    path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
    return path
  }
}

extension Color {
  /// A color from `0xRRGGBB` in `space`.
  fileprivate init(rgb: UInt32, space: RGBColorSpace = .sRGB) {
    self.init(
      space,
      red: Double((rgb >> 16) & 0xFF) / 255,
      green: Double((rgb >> 8) & 0xFF) / 255,
      blue: Double(rgb & 0xFF) / 255
    )
  }
}

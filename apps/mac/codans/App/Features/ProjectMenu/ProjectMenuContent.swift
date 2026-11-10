import CodansCore
import SwiftUI

/// The rows of a project menu: Recent, then the group sections. A project in
/// Recent is in its group too. The caller wraps each row in its own control,
/// so a picker can tag it for a checkmark and an action menu can make it a
/// button.
struct ProjectMenuContent<Row: View>: View {
  let menu: ProjectMenu
  /// `marksRemote` is `true` for a Recent row: a group section's title
  /// already names the Host.
  @ViewBuilder let row: (_ project: ProjectMenuOption, _ marksRemote: Bool) -> Row

  var body: some View {
    if !menu.recent.isEmpty {
      Section("Recent") {
        ForEach(menu.recent) { project in
          row(project, true)
        }
      }
    }
    ForEach(menu.sections) { section in
      Section(section.title) {
        ForEach(section.projects) { project in
          row(project, false)
        }
      }
    }
  }
}

/// A project menu row's label: the project's sidebar icon and its name, with
/// the remote marker when asked.
struct ProjectMenuRowLabel: View {
  let project: ProjectMenuOption
  var marksRemote = false

  var body: some View {
    Label {
      if marksRemote && project.isRemote {
        Text("\(project.name) \(Image(systemName: RemoteProjectMarker.symbol))")
          .accessibilityLabel("\(project.name), remote")
      } else {
        Text(project.name)
      }
    } icon: {
      Image(nsImage: Self.icon(project))
        .accessibilityHidden(true)
    }
    // A menu inside a grouped Form drops a row's icon by default; the
    // project icon is how the rows tell projects apart.
    .labelStyle(.titleAndIcon)
  }

  /// The project's sidebar icon, pre-rendered for a menu row: a menu draws
  /// an image, not a SwiftUI view, so a custom icon file needs this to show.
  static func icon(_ project: ProjectMenuOption?) -> NSImage {
    ProjectIconView.menuImage(
      icon: project?.icon, color: project?.color,
      defaultSymbol: project?.defaultSymbol ?? ProjectIconView.folderSymbol)
  }
}

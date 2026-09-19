import CodansCore
import ComposableArchitecture
import SwiftUI

/// Sheet for `CreateWorkspaceFeature`, laid out as a grouped form like the
/// Settings panes: the workspace (title, location, and the Add Project
/// menu), the list of projects with an edit and a remove button each, and
/// Cancel / Create in the bottom bar. Projects are added and edited in
/// `WorkspaceMemberEditorSheet`. In add mode the workspace is fixed and one
/// project is added to it.
struct CreateWorkspaceSheet: View {
  @Bindable var store: StoreOf<CreateWorkspaceFeature>
  @FocusState private var isTitleFocused: Bool

  var body: some View {
    // The bar sits below the form rather than over it, so rows never
    // scroll behind the buttons.
    VStack(spacing: 0) {
      form
      WorkspaceCreationBar(store: store)
    }
    .frame(width: 560)
    .frame(maxHeight: 760)
    .onAppear {
      if !store.isAddMode { isTitleFocused = true }
    }
    // `item:`, not `isPresented:`: the dialog's state is gone the moment it
    // closes, and a sheet whose content empties out mid-dismissal collapses
    // into a blank card on screen. The item hands the closing view what it
    // last held.
    .sheet(
      item: Binding(
        get: { store.editor },
        set: { editor in
          if editor == nil { store.send(.editor(.cancelTapped)) }
        }
      )
    ) { editor in
      WorkspaceMemberEditorSheet(store: store, opened: editor)
    }
  }

  private var form: some View {
    ScrollViewReader { proxy in
      Form {
        workspaceSection
        projectsSection
      }
      .formStyle(.grouped)
      .scrollBounceBehavior(.basedOnSize)
      .disabled(store.creation.isBusy)
      .onChange(of: store.members.count) { oldCount, newCount in
        guard newCount > oldCount, let last = store.members.last else { return }
        withAnimation(.easeInOut(duration: 0.2)) {
          proxy.scrollTo(last.id, anchor: .bottom)
        }
      }
    }
  }

  @ViewBuilder
  private var workspaceSection: some View {
    switch store.mode {
    case .create:
      Section {
        TextField(
          "Title",
          text: Binding(get: { store.titleDraft }, set: { store.send(.titleChanged($0)) }),
          prompt: Text("Checkout Flow")
        )
        .focused($isTitleFocused)
        locationRow
      } header: {
        Text("New Workspace")
        Text("A folder with a checkout of each project, for work that spans them.")
      } footer: {
        VStack(alignment: .leading, spacing: 10) {
          IssueList(issues: store.rootIssues)
          if store.members.isEmpty {
            addButtons
          }
        }
      }
      .headerProminence(.increased)
    case .add(_, let title, let rootPath, _):
      Section {
        LabeledContent("Workspace", value: title)
        LabeledContent("Location") {
          PathText(path: rootPath)
        }
      } header: {
        Text("Add Repository")
        Text("Check out one more project into this workspace.")
      } footer: {
        if store.members.isEmpty {
          addButtons
        }
      }
      .headerProminence(.increased)
    }
  }

  private var locationRow: some View {
    LabeledContent {
      HStack(spacing: 6) {
        PathText(path: store.rootPath.isEmpty ? store.locationPath : store.rootPath)
        Button {
          store.send(.chooseLocationTapped)
        } label: {
          Image(systemName: "folder")
            .accessibilityLabel("Choose Location")
        }
        .buttonStyle(.borderless)
        .help("Choose the folder to create the workspace in")
      }
    } label: {
      Text("Location")
    }
  }

  /// Below the list, or below the workspace section while the list is
  /// empty, the way Settings puts "Add…" buttons under a list: a project
  /// open in codans, any repository folder, or a remote to clone. Each
  /// opens a dialog to set up the checkout before it is listed.
  @ViewBuilder
  private var addButtons: some View {
    if store.canAddMembers {
      HStack(spacing: 8) {
        Menu {
          ForEach(store.availableCandidates) { candidate in
            Button {
              store.send(.addProjectTapped(candidate.id))
            } label: {
              Label(candidate.name, systemImage: Self.menuSymbol(for: candidate.icon))
            }
          }
        } label: {
          Text("Add Project")
        }
        .fixedSize()
        .disabled(store.availableCandidates.isEmpty)
        .help(
          store.availableCandidates.isEmpty
            ? "Every project open in codans is already in the list" : "Add a project that is open in codans")
        Button("Add Folder…") {
          store.send(.addFolderTapped)
        }
        .help("Add a repository folder from this Mac")
        Button("Add Remote…") {
          store.send(.addRemoteTapped)
        }
        .help("Add a repository to clone from a URL")
      }
      .foregroundStyle(.primary)
      .fixedSize(horizontal: false, vertical: true)
    }
  }

  /// Menus draw SF Symbols only; a custom project image falls back to the
  /// default glyph.
  private static func menuSymbol(for icon: ProjectIcon?) -> String {
    if case .symbol(let name) = icon { return name }
    return ProjectIconView.folderSymbol
  }

  @ViewBuilder
  private var projectsSection: some View {
    if !store.members.isEmpty {
      Section {
        ForEach(store.members) { member in
          WorkspaceMemberRow(store: store, member: member)
            .id(member.id)
        }
      } header: {
        Text(store.isAddMode ? "Project" : "Projects")
      } footer: {
        addButtons
      }
    }
  }
}

/// A path shown the way Settings shows one: home-relative, truncated in the
/// middle, selectable.
struct PathText: View {
  let path: String

  var body: some View {
    Text((path as NSString).abbreviatingWithTildeInPath)
      .foregroundStyle(.secondary)
      .lineLimit(1)
      .truncationMode(.middle)
      .textSelection(.enabled)
      .help(path)
      .frame(maxWidth: .infinity, alignment: .trailing)
  }
}

/// Issues as a section footer shows them: one line each, coloured by
/// severity. Incomplete fields are not listed; the bottom bar names the
/// first of them.
struct IssueList: View {
  let issues: [MemberIssue]

  var body: some View {
    let shown = issues.filter { $0.severity != .incomplete }
    if !shown.isEmpty {
      VStack(alignment: .leading, spacing: 2) {
        ForEach(Array(shown.enumerated()), id: \.offset) { _, issue in
          Text(issue.message)
            .foregroundStyle(color(for: issue.severity))
            .fixedSize(horizontal: false, vertical: true)
        }
      }
      .frame(maxWidth: .infinity, alignment: .leading)
    }
  }

  private func color(for severity: MemberIssue.Severity) -> Color {
    switch severity {
    case .blocking: return .red
    case .warning: return .orange
    case .info, .incomplete: return .secondary
    }
  }
}

/// Extracted so the sidebar's modifier chain stays under the type-checker
/// limit; an inline `.sheet` with binding + scope closures pushes it over.
struct CreateWorkspaceSheetPresenter: ViewModifier {
  @Bindable var store: StoreOf<HierarchySidebarFeature>

  func body(content: Content) -> some View {
    content.childSheet(
      store.scope(state: \.createWorkspaceSheet, action: \.createWorkspaceSheet),
      onDismiss: { store.send(.createWorkspaceSheet(.cancelButtonTapped)) },
      content: { childStore in
        CreateWorkspaceSheet(store: childStore)
          .interactiveDismissDisabled(store.createWorkspaceSheet?.creation.isBusy ?? false)
      }
    )
  }
}

import CodansCore
import ComposableArchitecture
import SwiftUI

/// Sheet for `CreateWorkspaceFeature`, laid out as a grouped form like the
/// Settings panes, with Cancel / Create in the bottom bar.
/// - Add Workspace: title and location, then the source projects with a
///   remove button each and the Add buttons below them.
/// - Add Project: the fixed Workspace, then one source project.
/// - New Group: name and branch, then one section per project with its
///   base ref, fetch, copy and agent options, findings, and progress.
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
      if !store.isAddSourceMode { isTitleFocused = true }
      store.send(.onAppear)
    }
    // `item:`, not `isPresented:`: the dialog's state is gone the moment it
    // closes, and a sheet whose content empties out mid-dismissal collapses
    // into a blank card on screen. The item hands the closing view what it
    // last held.
    .sheet(
      item: Binding(
        get: { store.remoteEditor },
        set: { editor in
          if editor == nil { store.send(.remote(.cancelTapped)) }
        }
      )
    ) { editor in
      WorkspaceRemoteSourceSheetView(store: store, opened: editor)
    }
  }

  private var form: some View {
    Form {
      switch store.mode {
      case .addWorkspace:
        workspaceSection
        sourcesSection
      case .addSource(_, let title, let rootPath, _):
        addSourceSection(title: title, rootPath: rootPath)
        sourcesSection
      case .newGroup(_, let title, _):
        groupSection(workspaceTitle: title)
        ForEach(store.groupMembers) { member in
          WorkspaceGroupMemberSectionView(store: store, member: member)
        }
      }
    }
    .formStyle(.grouped)
    .scrollBounceBehavior(.basedOnSize)
    .disabled(store.creation.isBusy || store.creation == .createdWithSetupFailures)
  }

  // MARK: Add Workspace

  private var workspaceSection: some View {
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
      Text("A folder that collects projects for work that spans them. Their checkouts stay as they are.")
    } footer: {
      IssueList(issues: store.rootIssues)
    }
    .headerProminence(.increased)
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

  // MARK: Add Project

  private func addSourceSection(title: String, rootPath: String) -> some View {
    Section {
      LabeledContent("Workspace", value: title)
      LabeledContent("Location") {
        PathText(path: rootPath)
      }
    } header: {
      Text("Add Project")
      Text("The project joins the default group as it is. No branch is created or changed.")
    }
    .headerProminence(.increased)
  }

  // MARK: Sources

  private var sourcesSection: some View {
    Section {
      ForEach(store.sources) { source in
        WorkspaceSourceRowView(store: store, source: source)
      }
    } header: {
      Text(store.isAddSourceMode ? "Project" : "Projects")
    } footer: {
      VStack(alignment: .leading, spacing: 10) {
        if store.isResolvingFolder {
          HStack(spacing: 6) {
            ProgressView().controlSize(.mini)
            Text("Checking the folder\u{2026}").foregroundStyle(.secondary)
          }
        }
        if let issue = store.sourceIssue {
          Text(issue)
            .foregroundStyle(.red)
            .fixedSize(horizontal: false, vertical: true)
        }
        addButtons
      }
      .frame(maxWidth: .infinity, alignment: .leading)
    }
  }

  /// Below the list, the way Settings puts "Add…" buttons under a list: a
  /// project open in codans, any repository folder, or a remote to clone.
  @ViewBuilder
  private var addButtons: some View {
    if store.canAddSources {
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
            ? "Every project open in codans is already listed" : "Add a project that is open in codans")
        Button("Add Folder\u{2026}") {
          store.send(.addFolderTapped)
        }
        .help("Add a repository folder from this Mac")
        Button("Add Remote\u{2026}") {
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

  // MARK: New Group

  private func groupSection(workspaceTitle: String) -> some View {
    Section {
      LabeledContent("Workspace", value: workspaceTitle)
      TextField(
        "Name",
        text: Binding(get: { store.groupName }, set: { store.send(.groupNameChanged($0)) }),
        prompt: Text("checkout-flow")
      )
      .focused($isTitleFocused)
      LabeledContent {
        TextField(
          "Branch",
          text: Binding(get: { store.branchDraft }, set: { store.send(.branchChanged($0)) }),
          prompt: Text(store.groupBranch.isEmpty ? "branch-name" : store.groupBranch)
        )
        .labelsHidden()
      } label: {
        Text("Branch")
        Text("Created in every project. Empty uses the group name.")
      }
    } header: {
      Text("New Group")
      Text("A folder with a new checkout of every project in the workspace, all on one branch.")
    } footer: {
      IssueList(issues: store.groupIssues)
    }
    .headerProminence(.increased)
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

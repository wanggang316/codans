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
      store.send(.onAppear)
      if !store.isAddMode { isTitleFocused = true }
    }
    .sheet(
      isPresented: Binding(
        get: { store.editor != nil },
        set: { isPresented in
          if !isPresented { store.send(.editor(.cancelTapped)) }
        }
      )
    ) {
      WorkspaceMemberEditorSheet(store: store)
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
        addProjectRow
      } header: {
        Text("New Workspace")
        Text("A folder with a checkout of each project, for work that spans them.")
      } footer: {
        IssueList(issues: store.rootIssues)
      }
      .headerProminence(.increased)
    case .add(_, let title, let rootPath, _):
      Section {
        LabeledContent("Workspace", value: title)
        LabeledContent("Location") {
          PathText(path: rootPath)
        }
        addProjectRow
      } header: {
        Text("Add Repository")
        Text("Check out one more project into this workspace.")
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

  /// The Settings panes' trailing "Add …" row, as a menu: a project comes
  /// from this Mac or from a URL, and each opens its own dialog.
  @ViewBuilder
  private var addProjectRow: some View {
    if store.canAddMembers {
      HStack {
        Menu {
          Button {
            store.send(.addLocalTapped)
          } label: {
            Label("Local Repository…", systemImage: "folder")
          }
          Button {
            store.send(.addRemoteTapped)
          } label: {
            Label("Remote Repository…", systemImage: "globe")
          }
        } label: {
          Label("Add Project", systemImage: "plus")
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        Spacer()
      }
    }
  }

  private var projectsSection: some View {
    Section {
      if store.members.isEmpty {
        Text(store.isAddMode ? "No project yet." : "No projects yet. A workspace needs at least two.")
          .foregroundStyle(.secondary)
      }
      ForEach(store.members) { member in
        WorkspaceMemberRow(store: store, member: member)
          .id(member.id)
      }
    } header: {
      Text(store.isAddMode ? "Project" : "Projects")
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
    content.sheet(
      isPresented: Binding(
        get: { store.createWorkspaceSheet != nil },
        set: { isPresented in
          if !isPresented {
            store.send(.createWorkspaceSheet(.cancelButtonTapped))
          }
        }
      )
    ) {
      if let childStore = store.scope(
        state: \.createWorkspaceSheet,
        action: \.createWorkspaceSheet
      ) {
        CreateWorkspaceSheet(store: childStore)
          .interactiveDismissDisabled(store.createWorkspaceSheet?.creation.isBusy ?? false)
      }
    }
  }
}

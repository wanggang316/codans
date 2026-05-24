import ComposableArchitecture
import SwiftUI
import TouchCodeCore

/// Branch popover content anchored at `WorktreeHeaderInfoLabel` (mounted by
/// T9). Pure projection of `BranchSwitcherFeature.State`: the reducer owns
/// the loads, the switch effect, and the HEAD-change reset; this view only
/// renders inventory + recent commits and dispatches tap actions.
///
/// Layout: 360 pt fixed width, ~480 pt max height, a single `ScrollView`
/// wrapping both sections (sections do not scroll independently).
struct BranchSwitcherView: View {
  @Bindable var store: StoreOf<BranchSwitcherFeature>

  /// Search field is rendered only when the inventory has any branches to
  /// filter. We hide it during load + empty-inventory states so the popover
  /// doesn't expose a dead control.
  private var shouldShowSearchField: Bool {
    guard let inventory = store.inventory else { return false }
    return !inventory.local.isEmpty || !inventory.remote.isEmpty
  }

  var body: some View {
    VStack(spacing: 0) {
      if shouldShowSearchField {
        searchField
      }
      ScrollView {
        VStack(alignment: .leading, spacing: 8) {
          branchesSection
          recentCommitsSection
        }
        .padding(.vertical, 8)
      }
      Divider().padding(.horizontal, 12)
      footer
    }
    .frame(width: 360)
    .frame(maxHeight: 480)
    .accessibilityIdentifier("branch_switcher.popover")
  }

  // MARK: - Search

  private var searchField: some View {
    // The reducer is not `BindableAction`-conformant, so we cannot use
    // `$store.searchQuery` directly. A manual `Binding` that forwards
    // writes through `.searchQueryChanged` keeps the reducer the sole
    // owner of the query state.
    let binding = Binding<String>(
      get: { store.searchQuery },
      set: { store.send(.searchQueryChanged($0)) }
    )
    return TextField("Filter branches", text: binding)
      .textFieldStyle(.roundedBorder)
      .controlSize(.small)
      .padding(.horizontal, 12)
      .padding(.top, 8)
      .padding(.bottom, 4)
      .accessibilityIdentifier("branch_switcher.search")
  }

  // MARK: - Branches section

  @ViewBuilder
  private var branchesSection: some View {
    VStack(alignment: .leading, spacing: 2) {
      sectionHeader("Branches")
      branchesBody
    }
  }

  @ViewBuilder
  private var branchesBody: some View {
    if store.inventoryLoading {
      sectionSpinner
    } else if let inventory = store.inventory {
      // Inventory loaded: render whatever survives the filter. When the
      // filter excludes everything we intentionally render nothing — the
      // spec hides the current-branch row on filter miss with no special
      // case, so a "No branches" message would be misleading here. The
      // section header alone signals an empty filtered result.
      let locals = filtered(inventory.local, query: store.searchQuery)
      let remotes = filtered(inventory.remote, query: store.searchQuery)
      ForEach(locals, id: \.shortName) { ref in
        let isCurrent = ref.shortName == inventory.current
        BranchRowView(
          ref: ref,
          isCurrent: isCurrent,
          onTap: {
            guard !isCurrent else { return }
            store.send(.branchTapped(target(for: ref, inventory: inventory)))
          }
        )
      }
      if !remotes.isEmpty {
        Divider().padding(.horizontal, 12)
        ForEach(remotes, id: \.shortName) { ref in
          BranchRowView(
            ref: ref,
            isCurrent: false,
            onTap: { store.send(.branchTapped(target(for: ref, inventory: inventory))) }
          )
        }
      }
    } else if store.inventoryError != nil {
      // Distinguish "couldn't load" from "no branches" so the user
      // doesn't mistake a transient git failure for a genuinely empty
      // inventory. The reducer logs the underlying error.
      emptyRow("Couldn't load branches")
    } else {
      // `inventory == nil && !inventoryLoading && inventoryError == nil`
      // — pre-fetch state only.
      emptyRow("No branches")
    }
  }

  // MARK: - Recent commits section

  @ViewBuilder
  private var recentCommitsSection: some View {
    VStack(alignment: .leading, spacing: 2) {
      sectionHeader("Recent commits")
      recentCommitsBody
    }
  }

  @ViewBuilder
  private var recentCommitsBody: some View {
    if store.commitsLoading {
      sectionSpinner
    } else if let commits = store.recentCommits, !commits.isEmpty {
      // The reducer already caps this list at 10; do not re-slice here.
      ForEach(commits, id: \.id) { commit in
        RecentCommitRowView(commit: commit)
      }
    } else if store.commitsError != nil {
      emptyRow("Couldn't load commits")
    } else {
      // `recentCommits == nil` (unloaded) or `recentCommits == []`
      // (loaded against a 0-commit branch) — same neutral copy.
      emptyRow("No commits")
    }
  }

  // MARK: - Footer

  private var footer: some View {
    HStack {
      Button("View all in Diff Viewer →") {
        store.send(.viewAllCommitsTapped)
      }
      .buttonStyle(.borderless)
      .accessibilityIdentifier("branch_switcher.view_all_button")
      Spacer()
    }
    .padding(12)
  }

  // MARK: - Section primitives

  private func sectionHeader(_ title: String) -> some View {
    Text(title)
      .font(.caption)
      .foregroundStyle(.secondary)
      .padding(.horizontal, 12)
  }

  private func emptyRow(_ message: String) -> some View {
    Text(message)
      .font(.body)
      .foregroundStyle(.secondary)
      .padding(.horizontal, 12)
      .padding(.vertical, 4)
  }

  private var sectionSpinner: some View {
    HStack {
      Spacer()
      ProgressView().controlSize(.small)
      Spacer()
    }
    .padding(.vertical, 6)
  }

  // MARK: - Filtering

  /// Case-insensitive substring match against `shortName`. Filtering lives
  /// in the view so the reducer can stay stateless w.r.t. the query — the
  /// only durable side-effect is the query string itself.
  private func filtered(_ refs: [BranchRef], query: String) -> [BranchRef] {
    let needle = query.trimmingCharacters(in: .whitespaces).lowercased()
    if needle.isEmpty { return refs }
    return refs.filter { $0.shortName.lowercased().contains(needle) }
  }

  // MARK: - Switch-target resolution

  /// Map a tapped `BranchRef` to the reducer's `BranchSwitchTarget`.
  ///
  /// Locals dispatch directly. Remotes prefer the fast-path of switching to
  /// an existing local that matches the post-prefix portion of the remote's
  /// short name (e.g. `origin/main` → local `main` when it exists); the
  /// `.remoteTracking` case is reserved for remotes with no matching local,
  /// where the service layer decides whether to materialise a tracking
  /// branch.
  private func target(for ref: BranchRef, inventory: BranchInventory) -> BranchSwitchTarget {
    guard ref.isRemote else { return .local(name: ref.shortName) }
    guard let stripped = strippedRemotePrefix(ref.shortName) else {
      return .remoteTracking(shortName: ref.shortName)
    }
    if inventory.local.contains(where: { $0.shortName == stripped }) {
      return .local(name: stripped)
    }
    return .remoteTracking(shortName: ref.shortName)
  }

  /// `origin/main` → `main`; `origin/feat/x` → `feat/x`. Returns nil when
  /// the short name lacks a `/`, which git would not normally emit for a
  /// remote-tracking ref but we handle defensively.
  private func strippedRemotePrefix(_ shortName: String) -> String? {
    guard let slash = shortName.firstIndex(of: "/") else { return nil }
    return String(shortName[shortName.index(after: slash)...])
  }
}

// MARK: - Previews

#Preview("populated") {
  BranchSwitcherView(
    store: Store(
      initialState: BranchSwitcherFeature.State(
        worktreeID: WorktreeID(),
        worktreePath: "/tmp/repo",
        projectID: ProjectID(),
        inventory: BranchInventory(
          current: "feat/header",
          local: [
            BranchRef(
              shortName: "feat/header",
              isRemote: false,
              upstream: "origin/feat/header"
            ),
            BranchRef(shortName: "bugfix/menu", isRemote: false, upstream: nil),
            BranchRef(shortName: "main", isRemote: false, upstream: "origin/main"),
          ],
          remote: [
            BranchRef(shortName: "origin/main", isRemote: true, upstream: nil),
            BranchRef(shortName: "origin/feat/new-shell", isRemote: true, upstream: nil),
          ]
        ),
        recentCommits: [
          Commit(
            id: "abcdef0123456789",
            authorName: "Ada Lovelace",
            authorEmail: "ada@example.com",
            date: Date().addingTimeInterval(-3_600),
            subject: "feat(switcher): wire popover content views",
            parents: []
          ),
          Commit(
            id: "1234567abcdef00",
            authorName: "Grace Hopper",
            authorEmail: "grace@example.com",
            date: Date().addingTimeInterval(-86_400),
            subject: "fix(diff): trim trailing whitespace in hunks",
            parents: []
          ),
          Commit(
            id: "fedcba9876543210",
            authorName: "Alan Turing",
            authorEmail: "alan@example.com",
            date: Date().addingTimeInterval(-7 * 86_400),
            subject: "refactor(git): extract branch inventory parser",
            parents: []
          ),
        ]
      ),
      reducer: { BranchSwitcherFeature() }
    )
  )
}

#Preview("loading") {
  BranchSwitcherView(
    store: Store(
      initialState: BranchSwitcherFeature.State(
        worktreeID: WorktreeID(),
        worktreePath: "/tmp/repo",
        projectID: ProjectID(),
        inventoryLoading: true,
        commitsLoading: true
      ),
      reducer: { BranchSwitcherFeature() }
    )
  )
}

#Preview("empty") {
  BranchSwitcherView(
    store: Store(
      initialState: BranchSwitcherFeature.State(
        worktreeID: WorktreeID(),
        worktreePath: "/tmp/repo",
        projectID: ProjectID(),
        inventory: BranchInventory(current: nil, local: [], remote: [])
      ),
      reducer: { BranchSwitcherFeature() }
    )
  )
}

#Preview("no remotes") {
  BranchSwitcherView(
    store: Store(
      initialState: BranchSwitcherFeature.State(
        worktreeID: WorktreeID(),
        worktreePath: "/tmp/repo",
        projectID: ProjectID(),
        inventory: BranchInventory(
          current: "main",
          local: [
            BranchRef(shortName: "main", isRemote: false, upstream: nil),
            BranchRef(shortName: "feat/wip", isRemote: false, upstream: nil),
          ],
          remote: []
        )
      ),
      reducer: { BranchSwitcherFeature() }
    )
  )
}

import ComposableArchitecture
import SwiftUI
import CodansCore

/// Branch popover content anchored at `WorktreeHeaderInfoLabel` (mounted by
/// T9). Pure projection of `BranchSwitcherFeature.State`: the reducer owns
/// the loads, the switch effect, and the HEAD-change reset; this view only
/// renders inventory and dispatches tap actions.
///
/// Layout: 360 pt fixed width, ~480 pt max height, a single `ScrollView`
/// wrapping the Branches section. The reducer still tracks
/// `recentCommits` (other surfaces consume it), but this popover no longer
/// renders them.
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
        }
        .padding(.vertical, 8)
      }
    }
    .frame(width: 360)
    // `minHeight` keeps the popover from collapsing to ~30pt on first open
    // when the inventory is still loading and the section body is just a
    // small ProgressView. Without a lower bound, the popover's intrinsic
    // size locks to the loading state's height and never expands once the
    // load completes (the popover doesn't re-measure mid-presentation).
    .frame(minHeight: 240, maxHeight: 480)
    .accessibilityIdentifier("branch_switcher.popover")
    .alert(
      store.creatingBranchFrom.map { "New branch from \($0)" } ?? "",
      isPresented: Binding(
        get: { store.creatingBranchFrom != nil },
        set: { newValue in
          if !newValue { store.send(.newBranchCancelled) }
        }
      )
    ) {
      TextField(
        "Branch name",
        text: Binding(
          get: { store.newBranchDraft },
          set: { store.send(.newBranchDraftChanged($0)) }
        )
      )
      .accessibilityIdentifier("branch_switcher.new_branch_field")
      Button("Create") {
        store.send(.newBranchConfirmed)
      }
      Button("Cancel", role: .cancel) {
        store.send(.newBranchCancelled)
      }
    } message: {
      Text("Create a new branch from this commit and switch to it.")
    }
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
      branchesSectionHeader
      branchesBody
    }
  }

  /// Branches section header.
  private var branchesSectionHeader: some View {
    HStack {
      Text("Branches")
        .font(.caption)
        .foregroundStyle(.secondary)
      Spacer()
    }
    .padding(.horizontal, 12)
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
        // Phase B: only LOCAL rows are marked blocked. A remote ref with
        // a stripped short-name matching a blocked local is still visible
        // (you can examine the remote-tracking ref) — semantically the
        // block is on the local, not the remote.
        let blockingWorktreeName = store.blockedBranches[ref.shortName]
        BranchRowView(
          ref: ref,
          isCurrent: isCurrent,
          blockingWorktreeName: blockingWorktreeName,
          isRenaming: store.renamingBranch == ref.shortName,
          renameInFlight: store.renameInFlight,
          renameDraft: Binding(
            get: { store.renameDraft },
            set: { store.send(.renameDraftChanged($0)) }
          ),
          onSwitch: {
            guard !isCurrent, blockingWorktreeName == nil else { return }
            store.send(.branchTapped(target(for: ref, inventory: inventory)))
          },
          onNewBranchFrom: {
            store.send(.newBranchButtonTapped(baseBranchName: ref.shortName))
          },
          onRename: {
            store.send(.renameButtonTapped(branchName: ref.shortName))
          },
          onRenameConfirm: { store.send(.renameConfirmed) },
          onRenameCancel: { store.send(.renameCancelled) }
        )
      }
      if !remotes.isEmpty {
        Divider().padding(.horizontal, 12)
        ForEach(remotes, id: \.shortName) { ref in
          BranchRowView(
            ref: ref,
            isCurrent: false,
            blockingWorktreeName: nil,
            isRenaming: false,
            renameInFlight: false,
            renameDraft: .constant(""),
            onSwitch: {
              store.send(.branchTapped(target(for: ref, inventory: inventory)))
            },
            onNewBranchFrom: {
              store.send(.newBranchButtonTapped(baseBranchName: ref.shortName))
            },
            onRename: {},
            onRenameConfirm: {},
            onRenameCancel: {}
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

  // MARK: - Section primitives

  private func emptyRow(_ message: String) -> some View {
    Text(message)
      .font(.body)
      .foregroundStyle(.secondary)
      .padding(.horizontal, 12)
      .padding(.vertical, 4)
  }

  private var sectionSpinner: some View {
    // Take the full available area so the spinner reads as centered in the
    // popover's `minHeight`-stretched body during the first load (instead
    // of hugging the top edge with a thin strip of empty space below).
    ProgressView()
      .controlSize(.small)
      .frame(maxWidth: .infinity, maxHeight: .infinity)
      .padding(.vertical, 6)
  }

  // MARK: - Filtering

  /// Case-insensitive substring match against `shortName`. Filtering lives
  /// in the view so the reducer can stay stateless w.r.t. the query — the
  /// only durable side-effect is the query string itself.
  private func filtered(_ refs: [BranchRef], query: String) -> [BranchRef] {
    let needle = query.trimmingCharacters(in: .whitespaces).lowercased()
    if needle.isEmpty { return refs }
    // `range(of:options:)` with `.caseInsensitive` avoids allocating a
    // lowercased copy of every haystack per render — meaningful when the
    // user types into a repo with hundreds of refs.
    return refs.filter {
      $0.shortName.range(of: needle, options: [.caseInsensitive]) != nil
    }
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

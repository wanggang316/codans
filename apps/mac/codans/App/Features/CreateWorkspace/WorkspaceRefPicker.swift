import SwiftUI

/// A form row choosing a git ref: a pop-up menu of the repository's
/// branches, grouped Local / Remote, with a first item for "none" (the
/// default base, or nothing chosen yet). While branches load, or when they
/// could not be listed, the row shows that instead of an empty menu.
///
/// Built from `Menu` and `Button` rather than `Picker` because a branch
/// another worktree holds has to be listed but not pickable, and
/// `.disabled` on a `Picker`'s content does not reach the menu item — the
/// item stays enabled, and the user learns of the refusal only after
/// choosing. A `Button` disables for real.
struct WorkspaceRefPicker: View {
  let title: String
  let refs: MemberDraft.RefsState
  let selection: String?
  /// Title of the first item, which stands for a nil selection.
  let placeholder: String
  let includeLocal: Bool
  let includeRemote: Bool
  /// Whether a branch another worktree holds can be chosen here. Checking
  /// one out is what git refuses, so that menu offers it disabled; starting
  /// a new branch from one is fine, so that menu leaves it selectable.
  var blocksCheckedOut = false
  /// Second line under the title, when the choice needs a word.
  var subtitle: String?
  let onSelect: (String?) -> Void

  var body: some View {
    LabeledContent {
      if let inventory = refs.inventory {
        Menu(selection ?? placeholder) {
          menuItems(inventory)
        }
        .fixedSize()
      } else if refs.isLoading {
        HStack(spacing: 6) {
          ProgressView().controlSize(.small)
          Text("Loading…").foregroundStyle(.secondary)
        }
      } else {
        Text(selection ?? placeholder).foregroundStyle(.secondary)
      }
    } label: {
      Text(title)
      if let subtitle {
        Text(subtitle)
      }
    }
  }

  @ViewBuilder
  private func menuItems(_ inventory: RefInventory) -> some View {
    let locals = includeLocal ? inventory.local : []
    let remotes = includeRemote ? inventory.remote : []
    item(placeholder, ref: nil, inventory)
    if !locals.isEmpty {
      Section("Local") {
        ForEach(locals, id: \.self) { branch in
          item(branch, ref: branch, inventory)
        }
      }
    }
    if !remotes.isEmpty {
      Section("Remote") {
        ForEach(remotes, id: \.self) { ref in
          item(ref, ref: ref, inventory)
        }
      }
    }
    // A selection the repository no longer lists still needs an item, or
    // the menu would show nothing marked.
    if let selection, !locals.contains(selection), !remotes.contains(selection) {
      item(selection, ref: selection, inventory)
    }
  }

  /// One branch, marked when it is the current choice. A branch another
  /// worktree already holds is listed but disabled, so the refusal arrives
  /// in the menu rather than as an error under a choice already made. The
  /// folder holding it is left out: a worktree's own folder is named after
  /// its branch, so the path would mostly repeat the ref back, and a long
  /// one widens the button.
  private func item(_ label: String, ref: String?, _ inventory: RefInventory) -> some View {
    let isTaken = blocksCheckedOut && ref.map { inventory.checkoutHolder(for: $0) != nil } == true
    // A Toggle is how a menu item carries the checkmark a pop-up button
    // marks its current choice with; `Menu` has no selection of its own.
    return Toggle(
      isTaken ? "\(label) — checked out" : label,
      isOn: Binding(get: { ref == selection }, set: { if $0 { onSelect(ref) } })
    )
    .disabled(isTaken)
  }
}

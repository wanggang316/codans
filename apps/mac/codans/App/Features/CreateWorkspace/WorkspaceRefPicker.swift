import SwiftUI

/// A form row choosing a git ref: a pop-up menu of the repository's
/// branches, grouped Local / Remote, with a first item for "none" (the
/// default base, or nothing chosen yet). While branches load, or when they
/// could not be listed, the row shows that instead of an empty menu.
struct WorkspaceRefPicker: View {
  let title: String
  let refs: MemberDraft.RefsState
  let selection: String?
  /// Title of the first item, which stands for a nil selection.
  let placeholder: String
  let includeLocal: Bool
  let includeRemote: Bool
  /// Second line under the title, when the choice needs a word.
  var subtitle: String?
  let onSelect: (String?) -> Void

  var body: some View {
    if let inventory = refs.inventory {
      Picker(selection: Binding(get: { selection ?? "" }, set: { onSelect($0.isEmpty ? nil : $0) })) {
        menuItems(inventory)
      } label: {
        Text(title)
        if let subtitle {
          Text(subtitle)
        }
      }
    } else {
      LabeledContent(title) {
        if refs.isLoading {
          HStack(spacing: 6) {
            ProgressView().controlSize(.small)
            Text("Loading…").foregroundStyle(.secondary)
          }
        } else {
          Text(selection ?? placeholder).foregroundStyle(.secondary)
        }
      }
    }
  }

  @ViewBuilder
  private func menuItems(_ inventory: RefInventory) -> some View {
    let locals = includeLocal ? inventory.local : []
    let remotes = includeRemote ? inventory.remote : []
    Text(placeholder).tag("")
    if !locals.isEmpty {
      Section("Local") {
        ForEach(locals, id: \.self) { branch in
          Text(branch).tag(branch)
        }
      }
    }
    if !remotes.isEmpty {
      Section("Remote") {
        ForEach(remotes, id: \.self) { ref in
          Text(ref).tag(ref)
        }
      }
    }
    // A selection the repository no longer lists still needs an item, or
    // the menu would show nothing selected.
    if let selection, !locals.contains(selection), !remotes.contains(selection) {
      Text(selection).tag(selection)
    }
  }
}

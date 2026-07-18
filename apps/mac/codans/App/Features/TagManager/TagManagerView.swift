import ComposableArchitecture
import SwiftUI
import CodansCore

/// CRUD sheet for catalog tags. Plain `VStack` (no `NavigationStack`)
/// driven by `hierarchyManager.catalog.tags` (single source of truth —
/// the reducer owns no tag values, only the rename / removal transients).
///
/// Layout, top → bottom: header (icon + "Tags") · tag list · bottom bar
/// (collapsed `+` button or expanded create-form) · footer (Done).
struct TagManagerSheet: View {
  @Bindable var store: StoreOf<TagManagerFeature>
  @Environment(HierarchyManager.self) private var hierarchyManager
  @Environment(\.dismiss) private var dismissEnv

  // Inline create-row state. Lives at the View level — these drafts
  // never need to round-trip through the reducer; on Add we send a
  // single `.createTagTapped(name, color)` and reset locally.
  @State private var isAdding = false
  @State private var newTagName: String = ""
  @State private var newTagColor: TagColor = .blue
  @FocusState private var renameFocused: Bool
  @FocusState private var newTagFocused: Bool

  /// Horizontal padding shared by header, bottom bar, and footer so the
  /// first column (icon / swatch / button label) aligns vertically with
  /// the swatches inside the list rows.
  private static let edgeX: CGFloat = 18

  /// HoverableTagRow's inner horizontal padding. Used in the inset math
  /// below — keep in sync with the value in `HoverableTagRow.body`.
  private static let rowInnerPad: CGFloat = 6

  /// Visual offset of a 14pt disc inside its 22pt swatch cell —
  /// `(22 - 14) / 2`. Subtracted from the list's leading inset so the
  /// disc's *visible* left edge lines up with the header glyph instead
  /// of the cell's invisible bounding box.
  private static let swatchCellOffset: CGFloat = 4

  var body: some View {
    VStack(spacing: 0) {
      header
      Divider()
      tagList
      Divider()
      bottomBar
      Divider()
      doneFooter
    }
    .frame(minWidth: 322, minHeight: 380)
    .confirmationDialog(
      confirmationTitle,
      isPresented: Binding(
        get: { store.pendingRemoval != nil },
        set: { if !$0 { store.send(.removeCancelled) } }
      ),
      titleVisibility: .visible
    ) {
      Button("Remove Tag", role: .destructive) {
        store.send(.removeConfirmed)
      }
      Button("Cancel", role: .cancel) {
        store.send(.removeCancelled)
      }
    } message: {
      Text(confirmationMessage)
    }
  }

  // MARK: - Header

  /// Single header band — just the "Tags" title. Replaces the prior
  /// NavigationStack title bar so the sheet only owns one header.
  private var header: some View {
    HStack(spacing: 0) {
      Text("Tags")
        .font(.headline)
      Spacer()
    }
    .padding(.horizontal, Self.edgeX)
    .padding(.top, 14)
    .padding(.bottom, 12)
  }

  // MARK: - Tag list

  private var tagList: some View {
    let tags = hierarchyManager.catalog.tags
    return Group {
      if tags.isEmpty {
        emptyState
      } else {
        List {
          ForEach(Array(tags.enumerated()), id: \.element.id) { index, tag in
            tagRow(tag)
              .listRowSeparator(.hidden)
              .listRowBackground(
                Color(
                  nsColor: NSColor.alternatingContentBackgroundColors[
                    index.isMultiple(of: 2) ? 1 : 0
                  ]
                )
              )
              .listRowInsets(
                EdgeInsets(
                  top: 0,
                  leading: Self.edgeX - Self.rowInnerPad - Self.swatchCellOffset,
                  bottom: 0,
                  trailing: Self.edgeX - Self.rowInnerPad
                )
              )
          }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
      }
    }
  }

  private var emptyState: some View {
    VStack(spacing: 8) {
      Spacer()
      Image(systemName: "tag")
        .font(.title)
        .foregroundStyle(.secondary)
        .accessibilityHidden(true)
      Text("No tags yet.")
        .foregroundStyle(.secondary)
      Text("Click + below to add one.")
        .font(.caption)
        .foregroundStyle(.tertiary)
      Spacer()
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
  }

  @ViewBuilder
  private func tagRow(_ tag: Tag) -> some View {
    HoverableTagRow {
      ColorSwatchPicker(
        selected: tag.color,
        onPick: { store.send(.recolor(tag.id, $0)) }
      )
      nameField(tag: tag)
      Spacer(minLength: 8)
    } trailing: {
      Button {
        store.send(.removeTapped(tag.id, name: tag.name))
      } label: {
        Image(systemName: "minus.circle.fill")
          .font(.system(size: 14))
          .foregroundStyle(.secondary)
          .symbolRenderingMode(.hierarchical)
      }
      .buttonStyle(.plain)
      .help("Remove Tag")
    }
  }

  /// Inline-editable name. Tap converts the Text to a TextField; Submit
  /// commits, Esc cancels. The reducer holds the draft so a re-render
  /// (catalog mutation from a sibling action) doesn't blow away the
  /// half-typed name.
  @ViewBuilder
  private func nameField(tag: Tag) -> some View {
    if store.renameDraft?.tagID == tag.id {
      TextField(
        "Tag name",
        text: Binding(
          get: { store.renameDraft?.text ?? tag.name },
          set: { store.send(.renameDraftChanged($0)) }
        )
      )
      .textFieldStyle(.plain)
      .focused($renameFocused)
      .onAppear { renameFocused = true }
      .onSubmit { store.send(.renameCommitted) }
      .onExitCommand { store.send(.renameCancelled) }
    } else {
      Text(tag.name)
        .contentShape(Rectangle())
        .onTapGesture {
          store.send(.renameRowTapped(tag.id, currentName: tag.name))
        }
    }
  }

  // MARK: - Bottom bar (Add affordance)

  /// Two states: a quiet `+ Add Tag` button by default; on click it
  /// expands inline into the new-tag form (color picker + name field +
  /// Cancel/Add). Esc or the Cancel button collapses the form back.
  @ViewBuilder
  private var bottomBar: some View {
    Group {
      if isAdding {
        addingForm
      } else {
        addButtonRow
      }
    }
    .background(.bar)
  }

  private var addButtonRow: some View {
    HStack(spacing: 6) {
      Button {
        beginAdding()
      } label: {
        Label("Add Tag", systemImage: "plus")
          .labelStyle(.titleAndIcon)
          .font(.callout)
      }
      .buttonStyle(.borderless)
      Spacer()
    }
    .padding(.horizontal, Self.edgeX)
    .padding(.vertical, 8)
  }

  /// Expanded create-form. The seven palette colors are shown inline
  /// as a horizontal strip — no popover hop while creating; you can see
  /// every option at once and pick directly. The text field auto-focuses
  /// on entry. Horizontal padding compensates for the swatch cell's
  /// internal offset so the first disc's visible left edge aligns with
  /// the header glyph above and the list-row swatches.
  private var addingForm: some View {
    VStack(alignment: .leading, spacing: 8) {
      ColorRowPicker(
        selected: newTagColor,
        onPick: { newTagColor = $0 }
      )
      HStack(spacing: 8) {
        TextField("New tag name", text: $newTagName)
          .textFieldStyle(.roundedBorder)
          .focused($newTagFocused)
          .onSubmit(commitNewTag)
          .onExitCommand { cancelAdding() }
        Button("Cancel", action: cancelAdding)
          .buttonStyle(.borderless)
          .keyboardShortcut(.cancelAction)
        Button("Add", action: commitNewTag)
          .keyboardShortcut(.defaultAction)
          .disabled(newTagName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
      }
    }
    .padding(.leading, Self.edgeX - Self.swatchCellOffset)
    .padding(.trailing, Self.edgeX)
    .padding(.vertical, 10)
  }

  private func beginAdding() {
    newTagName = ""
    newTagColor = .blue
    isAdding = true
    // Defer focus so the TextField is mounted before we focus it.
    DispatchQueue.main.async { newTagFocused = true }
  }

  private func commitNewTag() {
    let trimmed = newTagName.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return }
    store.send(.createTagTapped(name: trimmed, color: newTagColor))
    newTagName = ""
    isAdding = false
  }

  private func cancelAdding() {
    newTagName = ""
    isAdding = false
  }

  // MARK: - Footer (Done)

  private var doneFooter: some View {
    HStack {
      Spacer()
      Button("Done") { dismissEnv() }
        .keyboardShortcut(.defaultAction)
    }
    .padding(.horizontal, Self.edgeX)
    .padding(.vertical, 10)
  }

  // MARK: - Confirmation strings

  private var confirmationTitle: String {
    let name = store.pendingRemoval?.displayName ?? ""
    return "Remove tag \"\(name)\"?"
  }

  private var confirmationMessage: String {
    let count = store.pendingRemoval?.affectedProjectCount ?? 0
    if count == 1 {
      return "1 project will lose this tag. Project data is not affected."
    }
    return "\(count) projects will lose this tag. Project data is not affected."
  }
}

// MARK: - Color swatch picker (popover)

/// Single colored disc that opens a popover with the seven palette
/// colors when tapped. Used for editing the color of an existing tag,
/// where always-visible 7 dots per row would clutter the steady-state
/// list.
private struct ColorSwatchPicker: View {
  let selected: TagColor
  let onPick: (TagColor) -> Void

  @State private var isPopoverPresented = false

  var body: some View {
    Button {
      isPopoverPresented.toggle()
    } label: {
      Circle()
        .fill(swiftUIColor(for: selected))
        .frame(width: 14, height: 14)
        .overlay(
          Circle().strokeBorder(Color.primary.opacity(0.18), lineWidth: 0.5)
        )
        .frame(width: 22, height: 22)
        .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .help("Change Color")
    .popover(isPresented: $isPopoverPresented, arrowEdge: .top) {
      HStack(spacing: 10) {
        ForEach(TagColor.allCases, id: \.self) { color in
          Button {
            onPick(color)
            isPopoverPresented = false
          } label: {
            popoverSwatch(color: color, isSelected: color == selected)
          }
          .buttonStyle(.plain)
          .help(color.rawValue.capitalized)
          .accessibilityLabel(color.rawValue.capitalized)
          .accessibilityAddTraits(color == selected ? [.isSelected] : [])
        }
      }
      .padding(.horizontal, 12)
      .padding(.vertical, 10)
    }
  }

  @ViewBuilder
  private func popoverSwatch(color: TagColor, isSelected: Bool) -> some View {
    ZStack {
      Circle()
        .fill(swiftUIColor(for: color))
        .frame(width: 20, height: 20)
      if isSelected {
        Circle()
          .strokeBorder(Color.accentColor, lineWidth: 2)
          .frame(width: 26, height: 26)
        Image(systemName: "checkmark")
          .font(.system(size: 11, weight: .bold))
          .foregroundStyle(.white)
          .shadow(color: .black.opacity(0.25), radius: 0.5, y: 0.5)
      }
    }
    .frame(width: 28, height: 28)
    .contentShape(Rectangle())
  }
}

// MARK: - Inline color row picker (used by the create-form)

/// Horizontal strip of every `TagColor`. Tapping a disc commits the
/// color immediately. The current selection draws a 1.5pt dark ring
/// around itself so the active hue stays unambiguous against same-hue
/// neighbors.
private struct ColorRowPicker: View {
  let selected: TagColor
  let onPick: (TagColor) -> Void

  var body: some View {
    HStack(spacing: 8) {
      ForEach(TagColor.allCases, id: \.self) { color in
        Button {
          if color != selected { onPick(color) }
        } label: {
          swatchCell(color: color, isSelected: color == selected)
        }
        .buttonStyle(.plain)
        .help(color.rawValue.capitalized)
        .accessibilityLabel(color.rawValue.capitalized)
        .accessibilityAddTraits(color == selected ? [.isSelected] : [])
      }
    }
  }

  @ViewBuilder
  private func swatchCell(color: TagColor, isSelected: Bool) -> some View {
    ZStack {
      Circle()
        .fill(swiftUIColor(for: color))
        .frame(width: 16, height: 16)
        .overlay(
          Circle().strokeBorder(Color.black.opacity(0.10), lineWidth: 0.5)
        )
      if isSelected {
        Circle()
          .strokeBorder(Color.primary.opacity(0.85), lineWidth: 1.5)
          .frame(width: 22, height: 22)
      }
    }
    .frame(width: 24, height: 24)
    .contentShape(Rectangle())
  }
}

// MARK: - Hover row

/// Wraps a tag list row so the trailing affordance (delete button) only
/// reveals on hover — matches Finder's Tags preferences pane and keeps
/// the steady-state list visually quiet. Hover background gives a faint
/// highlight without painting a full selection bar.
private struct HoverableTagRow<Leading: View, Trailing: View>: View {
  @ViewBuilder let leading: () -> Leading
  @ViewBuilder let trailing: () -> Trailing
  @State private var isHovering = false

  var body: some View {
    HStack(spacing: 10) {
      leading()
      trailing()
        .opacity(isHovering ? 1 : 0)
    }
    .padding(.horizontal, 6)
    .padding(.vertical, 7)
    .contentShape(Rectangle())
    .onHover { isHovering = $0 }
  }
}

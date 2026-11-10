import CodansCore
import SwiftUI

/// The open skill list of a `ComposerSkillCompletion`, drawn as a menu card
/// in `ComposerSkillCompletionPanel`: one row per match with an icon for its
/// source, its name, and, quieter, the first line of its description and
/// its source. The highlighted row has the system selection color and
/// follows the arrow keys; a click picks a row.
struct ComposerSkillCompletionList: View {
  private typealias Layout = ComposerSkillCompletionPanelLayout

  let completion: ComposerSkillCompletion
  let text: String
  let selection: ComposerSelection
  let onInsert: (String) -> Void

  var body: some View {
    ScrollViewReader { proxy in
      ScrollView {
        LazyVStack(alignment: .leading, spacing: 0) {
          ForEach(Array(completion.matches.enumerated()), id: \.element.id) { index, skill in
            Button {
              _ = selection.apply(completion.select(skill, text: text), onInsert: onInsert)
            } label: {
              row(skill, isHighlighted: index == completion.highlightedIndex)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .focusable(false)
            .id(skill.id)
          }
        }
        .padding(.vertical, Layout.verticalPadding)
        .padding(.horizontal, Layout.horizontalPadding)
      }
      .scrollIndicators(.automatic)
      .onChange(of: completion.highlighted?.id) { _, id in
        if let id { proxy.scrollTo(id) }
      }
    }
    .accessibilityElement(children: .contain)
    .accessibilityLabel("Skills")
  }

  private func row(_ skill: AgentSkillEntry, isHighlighted: Bool) -> some View {
    let secondary: AnyShapeStyle = isHighlighted ? AnyShapeStyle(.white.opacity(0.8)) : AnyShapeStyle(.secondary)
    return HStack(spacing: 6) {
      Image(systemName: Self.symbol(for: skill.source))
        .frame(width: 16)
        .foregroundStyle(secondary)
        // The source text says the same.
        .accessibilityHidden(true)
      Text(skill.name)
        .foregroundStyle(isHighlighted ? AnyShapeStyle(.white) : AnyShapeStyle(.primary))
        .lineLimit(1)
        .layoutPriority(1)
      if let summary = skill.summary {
        Text(summary)
          .foregroundStyle(secondary)
          .lineLimit(1)
          .truncationMode(.tail)
      }
      Spacer(minLength: 8)
      Text(skill.source.rawValue)
        .font(.caption)
        .foregroundStyle(secondary)
    }
    .font(.system(size: NSFont.systemFontSize))
    .padding(.horizontal, 6)
    .frame(height: Layout.rowHeight)
    .background(
      isHighlighted
        ? AnyShapeStyle(Color(nsColor: .selectedContentBackgroundColor)) : AnyShapeStyle(.clear),
      in: RoundedRectangle(cornerRadius: 4)
    )
    .help(skill.summary ?? "")
    .accessibilityElement(children: .combine)
    .accessibilityAddTraits(isHighlighted ? .isSelected : [])
  }

  private static func symbol(for source: AgentSkillSource) -> String {
    switch source {
    case .user: "person"
    case .project: "folder"
    case .plugin: "puzzlepiece.extension"
    }
  }
}

/// Button a composer keeps beside its file picker: puts the selected
/// agent's skill call prefix at the caret, so the skill list opens there.
/// Disabled with `unavailableReason` as its tooltip when the composer
/// offers no skills.
struct ComposerSkillsButton: View {
  let unavailableReason: String?
  let action: () -> Void

  var body: some View {
    Button(action: action) {
      Image(systemName: "sparkles")
        .frame(width: 28, height: 28)
        .contentShape(Rectangle())
    }
    .buttonStyle(.borderless)
    .disabled(unavailableReason != nil)
    .help(unavailableReason ?? "Insert a skill")
    .accessibilityLabel("Skills")
    .accessibilityHint(unavailableReason ?? "")
  }
}

extension View {
  /// Drives `completion` from a composer editor and owns the editor's
  /// Return and Escape. The open list takes Return, Tab, the arrows, and
  /// Escape. With it closed, Return calls `onSubmit` (⇧Return and ⌥Return
  /// break a line) and Escape calls `onCancel`.
  ///
  /// The owner's Return and Escape live here, not in its own `onKeyPress`
  /// handlers: SwiftUI offers a key press to the outermost handler first,
  /// so a separate handler could take Return from an open list.
  func composerSkillCompletion(
    _ completion: ComposerSkillCompletion,
    text: String,
    selection: ComposerSelection,
    onInsert: @escaping (String) -> Void,
    onSubmit: @escaping () -> Void,
    onCancel: @escaping () -> Void
  ) -> some View {
    modifier(
      ComposerSkillCompletionKeys(
        completion: completion, text: text, selection: selection, onInsert: onInsert,
        onSubmit: onSubmit, onCancel: onCancel))
  }
}

private struct ComposerSkillCompletionKeys: ViewModifier {
  private struct Input: Equatable {
    var text: String
    var caretRevision: Int
  }

  let completion: ComposerSkillCompletion
  let text: String
  let selection: ComposerSelection
  let onInsert: (String) -> Void
  let onSubmit: () -> Void
  let onCancel: () -> Void

  func body(content: Content) -> some View {
    content
      // The open list floats in a child panel, so it never moves the
      // owner's layout.
      .background(
        ComposerSkillCompletionPanelAnchor(
          content: ComposerSkillCompletionList(
            completion: completion, text: text, selection: selection, onInsert: onInsert),
          rowCount: completion.isOpen ? completion.matches.count : 0,
          onResignKey: { [completion, text] in _ = completion.handle(.dismiss, text: text) }
        )
      )
      // Text and caret together: SwiftUI reports the caret before it writes
      // the text, and both are current only when the view updates. A caret
      // move without a text change (a click) also recomputes the call.
      .onChange(of: Input(text: text, caretRevision: selection.revision)) { _, input in
        completion.update(text: input.text, caret: selection.completionCaret(in: input.text))
      }
      .onKeyPress(keys: [.return, .tab, .upArrow, .downArrow, .escape], phases: .down) { press in
        if let key = Self.listKey(for: press),
          selection.apply(completion.handle(key, text: text), onInsert: onInsert) == .handled
        {
          return .handled
        }
        switch press.key {
        case .return:
          if press.modifiers.contains(.shift) || press.modifiers.contains(.option) {
            return .ignored
          }
          onSubmit()
          return .handled
        case .escape:
          // `NSTextView` would spend Escape on word completion.
          onCancel()
          return .handled
        default:
          return .ignored
        }
      }
  }

  /// The list key for a press, or `nil` when the list does not take it.
  /// Arrow keys carry the function and numeric-pad flags, so only Return,
  /// Tab, and Escape need to be plain.
  private static func listKey(for press: KeyPress) -> ComposerSkillCompletion.Key? {
    switch press.key {
    case .upArrow: return .up
    case .downArrow: return .down
    case .escape where press.modifiers.isEmpty: return .dismiss
    case .return where press.modifiers.isEmpty, .tab where press.modifiers.isEmpty: return .accept
    default: return nil
    }
  }
}

extension ComposerSelection {
  /// Applies a completion outcome: hands the new text to the owner and
  /// puts the caret after the inserted call.
  func apply(
    _ outcome: ComposerSkillCompletion.KeyOutcome, onInsert: (String) -> Void
  ) -> KeyPress.Result {
    switch outcome {
    case .ignored:
      return .ignored
    case .handled:
      return .handled
    case .insert(let newText, let caret):
      onInsert(newText)
      moveCaret(toUTF16Offset: caret, in: newText)
      return .handled
    }
  }
}

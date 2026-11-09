import CodansCore
import SwiftUI

/// The open skill list of a `ComposerSkillCompletion`: one row per match
/// with its name, the first line of its description, and its source. The
/// highlighted row follows the arrow keys; a click picks a row.
struct ComposerSkillCompletionList: View {
  let completion: ComposerSkillCompletion
  let text: String
  let selection: ComposerSelection
  let onInsert: (String) -> Void

  /// About five rows.
  private static let maxHeight: CGFloat = 170

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
            // The editor keeps focus, so keys keep going to the list.
            .focusable(false)
            .id(skill.id)
          }
        }
        .padding(4)
      }
      .frame(maxHeight: Self.maxHeight)
      .fixedSize(horizontal: false, vertical: true)
      .onChange(of: completion.highlighted?.id) { _, id in
        if let id { proxy.scrollTo(id) }
      }
    }
    .background(.background.secondary, in: RoundedRectangle(cornerRadius: 8))
    .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.separator))
    .accessibilityElement(children: .contain)
    .accessibilityLabel("Skills")
  }

  private func row(_ skill: AgentSkillEntry, isHighlighted: Bool) -> some View {
    HStack(spacing: 8) {
      Text(skill.name)
        .font(.callout.weight(.medium))
        .lineLimit(1)
        .layoutPriority(1)
      if let summary = skill.summary {
        Text(summary)
          .font(.callout)
          .foregroundStyle(isHighlighted ? .primary : .secondary)
          .lineLimit(1)
          .truncationMode(.tail)
      }
      Spacer(minLength: 8)
      Text(skill.source.rawValue)
        .font(.caption)
        .foregroundStyle(.tertiary)
    }
    .padding(.horizontal, 8)
    .padding(.vertical, 5)
    .background(
      isHighlighted ? AnyShapeStyle(Color.accentColor.opacity(0.22)) : AnyShapeStyle(.clear),
      in: RoundedRectangle(cornerRadius: 5)
    )
    .accessibilityElement(children: .combine)
    .accessibilityAddTraits(isHighlighted ? .isSelected : [])
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

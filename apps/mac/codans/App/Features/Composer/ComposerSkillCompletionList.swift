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
            row(skill, isHighlighted: index == completion.highlightedIndex)
              .id(skill.id)
              .contentShape(Rectangle())
              .onTapGesture {
                _ = selection.apply(completion.select(skill, text: text), onInsert: onInsert)
              }
              .accessibilityAddTraits(.isButton)
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
  /// Drives `completion` from a composer editor: recomputes the list when
  /// the text changes and routes Return, Tab, the arrows, and Escape to the
  /// open list. With the list closed every key passes through, so the
  /// owner's own key handlers keep working. Apply it directly on the
  /// editor, before the owner's `onKeyPress` handlers, so it sees keys first.
  func composerSkillCompletion(
    _ completion: ComposerSkillCompletion,
    text: String,
    selection: ComposerSelection,
    onInsert: @escaping (String) -> Void
  ) -> some View {
    modifier(
      ComposerSkillCompletionKeys(
        completion: completion, text: text, selection: selection, onInsert: onInsert))
  }
}

private struct ComposerSkillCompletionKeys: ViewModifier {
  let completion: ComposerSkillCompletion
  let text: String
  let selection: ComposerSelection
  let onInsert: (String) -> Void

  func body(content: Content) -> some View {
    content
      .onChange(of: text) { _, newText in
        completion.update(text: newText, caret: selection.caret(in: newText))
      }
      .onKeyPress(keys: [.return, .tab, .upArrow, .downArrow, .escape], phases: .down) { press in
        guard press.modifiers.isEmpty || press.key == .upArrow || press.key == .downArrow else {
          return .ignored
        }
        let key: ComposerSkillCompletion.Key
        switch press.key {
        case .upArrow: key = .up
        case .downArrow: key = .down
        case .escape: key = .dismiss
        default: key = .accept
        }
        return selection.apply(completion.handle(key, text: text), onInsert: onInsert)
      }
      .onKeyPress(keys: [.leftArrow, .rightArrow], phases: .down) { _ in
        // The caret leaves the typed call; the list would go stale.
        completion.close()
        return .ignored
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

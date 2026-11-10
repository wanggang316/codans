import CodansCore
import SwiftUI

/// The open skill list of a `ComposerSkillCompletion`, drawn as a menu card
/// in `ComposerSkillCompletionPanel`: one row per match with an icon for its
/// source and its name. One row is current, as in a menu: the highlighted
/// row has the system selection color and follows the arrow keys and the
/// pointer (`ComposerSkillCompletionPointer`); Return, Tab, and a click
/// insert it. Its description goes to `onTooltipTarget`, which shows it
/// beside the list.
struct ComposerSkillCompletionList: View {
  private typealias Layout = ComposerSkillCompletionPanelLayout

  /// A description to show and the frame of its row, in the list's
  /// top-left coordinates.
  struct TooltipTarget: Equatable {
    var text: String
    var rowFrame: CGRect
  }

  let completion: ComposerSkillCompletion
  let text: String
  let selection: ComposerSelection
  let onInsert: (String) -> Void
  /// Set by the presenter that shows the tooltip.
  var onTooltipTarget: (TooltipTarget?) -> Void = { _ in }

  @State private var pointer = ComposerSkillCompletionPointer(at: NSEvent.mouseLocation)
  @State private var rowFrames: [String: CGRect] = [:]

  var body: some View {
    ScrollViewReader { proxy in
      ScrollView {
        LazyVStack(alignment: .leading, spacing: 0) {
          ForEach(Array(completion.matches.enumerated()), id: \.element.id) { index, skill in
            Button {
              completion.highlight(skill)
              _ = selection.apply(completion.select(skill, text: text), onInsert: onInsert)
            } label: {
              row(skill, isHighlighted: index == completion.highlightedIndex)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .focusable(false)
            .id(skill.id)
            .onContinuousHover { phase in
              if case .active = phase {
                pointer.hovered(skill, at: NSEvent.mouseLocation, in: completion)
              }
            }
            .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { frame in
              rowFrames[skill.id] = frame
            }
          }
        }
        .padding(.vertical, Layout.verticalPadding)
        .padding(.horizontal, Layout.horizontalPadding)
      }
      .scrollIndicators(.automatic)
      .onChange(of: completion.highlighted?.id) { _, id in
        if let id { proxy.scrollTo(id) }
      }
      // New rows under a resting pointer do not take the highlight: the
      // list opened, or refiltered, where the pointer already was.
      .onChange(of: completion.matches) { pointer = ComposerSkillCompletionPointer(at: NSEvent.mouseLocation) }
    }
    .onChange(of: tooltipTarget, initial: true) { _, target in onTooltipTarget(target) }
    .accessibilityElement(children: .contain)
    .accessibilityLabel("Skills")
  }

  /// The highlighted row's description. None for a skill without one or a
  /// row out of view.
  private var tooltipTarget: TooltipTarget? {
    guard let skill = completion.highlighted, let details = skill.details, let frame = rowFrames[skill.id]
    else { return nil }
    return TooltipTarget(text: details, rowFrame: frame)
  }

  private func row(_ skill: AgentSkillEntry, isHighlighted: Bool) -> some View {
    HStack(spacing: Layout.iconSpacing) {
      Image(systemName: Self.symbol(for: skill.source))
        .frame(width: Layout.iconWidth)
        .foregroundStyle(isHighlighted ? AnyShapeStyle(.white.opacity(0.85)) : AnyShapeStyle(.secondary))
      Text(skill.name)
        .foregroundStyle(isHighlighted ? AnyShapeStyle(.white) : AnyShapeStyle(.primary))
        .lineLimit(1)
        .truncationMode(.middle)
    }
    // Not a `Spacer`: the stack would put `iconSpacing` before it too and
    // take that from the name, which `Layout.width` does not count.
    .frame(maxWidth: .infinity, alignment: .leading)
    .font(Font(Layout.rowFont))
    .padding(.horizontal, Layout.rowHorizontalPadding)
    .frame(height: Layout.rowHeight)
    .background(
      isHighlighted
        ? AnyShapeStyle(Color(nsColor: .selectedContentBackgroundColor)) : AnyShapeStyle(.clear),
      in: RoundedRectangle(cornerRadius: 4)
    )
    .accessibilityElement(children: .ignore)
    .accessibilityLabel("\(skill.name), \(skill.source.rawValue)")
    .accessibilityAddTraits(isHighlighted ? [.isButton, .isSelected] : .isButton)
  }

  private static func symbol(for source: AgentSkillSource) -> String {
    switch source {
    case .user: "person"
    case .project: "folder"
    case .plugin: "puzzlepiece.extension"
    }
  }
}

/// Where the pointer was over the skill list, in screen coordinates. As in
/// `NSMenu`, the row under the pointer takes the highlight only when the
/// pointer itself moves: a row that comes under a resting pointer (the list
/// opens, scrolls, or refilters there) leaves the highlight to the keyboard.
/// The pointer leaving the list keeps the highlight.
@MainActor
struct ComposerSkillCompletionPointer {
  private var location: CGPoint

  init(at location: CGPoint) {
    self.location = location
  }

  mutating func hovered(
    _ skill: AgentSkillEntry, at location: CGPoint, in completion: ComposerSkillCompletion
  ) {
    guard location != self.location else { return }
    self.location = location
    completion.highlight(skill)
  }
}

/// The description beside the list, in the system tooltip font. It wraps
/// at `ComposerSkillCompletionPanelLayout.tooltipMaxWidth`.
struct ComposerSkillCompletionTooltip: View {
  let text: String

  var body: some View {
    Text(text)
      .font(Font(NSFont.toolTipsFont(ofSize: 0)))
      .foregroundStyle(.primary)
      .fixedSize(horizontal: false, vertical: true)
      .padding(.horizontal, ComposerSkillCompletionPanelLayout.tooltipHorizontalPadding)
      .padding(.vertical, ComposerSkillCompletionPanelLayout.tooltipVerticalPadding)
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
  /// break a line) and Escape calls `onCancel`. While an input method
  /// composes, all of them go to the input method.
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
          names: completion.isOpen ? completion.matches.map(\.name) : [],
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
        // While an input method composes, these keys confirm, cancel, or
        // pick its text.
        if selection.hasMarkedText { return .ignored }
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

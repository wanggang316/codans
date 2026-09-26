import CodansIPC
import UIKit

/// App shortcuts a hardware keyboard reaches with ⌘.
enum TerminalHardwareShortcut: Equatable {
  case previousPane
  case nextPane
  case tab(Int)
  case newTab
  case splitRight
  case splitDown
  case zoomIn
  case zoomOut
  /// ⌘K: clear the pane with Ctrl+L, which the pane itself handles; the
  /// Mac's ⌘K binding is never pressed remotely.
  case clear
}

/// The terminal's keyboard. It holds no document: committed text leaves at
/// once, and only IME marked text (pinyin, kana, …) stays here until the
/// input method commits it — sending a composition half-formed would type
/// it into the shell. Hardware keys that type nothing, and ctrl / alt
/// chords, are taken in `pressesBegan` as W3C key events; everything else
/// goes through the text system so input methods keep working.
final class TerminalInputView: UIView, UITextInput {
  var onText: (String) -> Void = { _ in }
  var onKey: (_ code: String, _ mods: IPC.TerminalKeyModifiers) -> Void = { _, _ in }
  var onPaste: (String) -> Void = { _ in }
  var onMarkedTextChange: (String?) -> Void = { _ in }
  var onShortcut: (TerminalHardwareShortcut) -> Void = { _ in }

  /// Composition in progress; empty when none.
  private(set) var markedText = ""
  private var markedSelection = NSRange(location: 0, length: 0)

  /// With the software keyboard hidden the accessory (the key bar) stays
  /// on screen: an empty input view replaces the keyboard.
  var showsSoftwareKeyboard = true {
    didSet {
      guard showsSoftwareKeyboard != oldValue else { return }
      inputView = showsSoftwareKeyboard ? nil : UIView(frame: .zero)
      if isFirstResponder { reloadInputViews() }
    }
  }

  private var accessory: UIView?
  override var inputAccessoryView: UIView? {
    get { accessory }
    set { accessory = newValue }
  }

  private var customInputView: UIView?
  override var inputView: UIView? {
    get { customInputView }
    set { customInputView = newValue }
  }

  // MARK: - UITextInputTraits

  var autocorrectionType: UITextAutocorrectionType = .no
  var autocapitalizationType: UITextAutocapitalizationType = .none
  var spellCheckingType: UITextSpellCheckingType = .no
  var smartQuotesType: UITextSmartQuotesType = .no
  var smartDashesType: UITextSmartDashesType = .no
  var smartInsertDeleteType: UITextSmartInsertDeleteType = .no
  var inlinePredictionType: UITextInlinePredictionType = .no
  var keyboardType: UIKeyboardType = .default
  var returnKeyType: UIReturnKeyType = .default
  var textContentType: UITextContentType! = nil

  override var canBecomeFirstResponder: Bool { true }

  // MARK: - UIKeyInput

  /// Always true, so Backspace on an empty line still reaches the pane.
  var hasText: Bool { true }

  func insertText(_ text: String) {
    let hadMarked = !markedText.isEmpty
    setMarked("")
    if hadMarked { inputDelegate?.textDidChange(self) }
    guard !text.isEmpty else { return }
    onText(text)
  }

  func deleteBackward() {
    if !markedText.isEmpty {
      var text = markedText
      text.removeLast()
      setMarked(text)
      return
    }
    onKey("Backspace", .none)
  }

  // MARK: - Marked text

  func setMarkedText(_ markedText: String?, selectedRange: NSRange) {
    markedSelection = selectedRange
    setMarked(markedText ?? "")
  }

  func unmarkText() {
    let committed = markedText
    setMarked("")
    if !committed.isEmpty { onText(committed) }
  }

  func setAttributedMarkedText(_ markedText: NSAttributedString?, selectedRange: NSRange) {
    setMarkedText(markedText?.string, selectedRange: selectedRange)
  }

  private func setMarked(_ text: String) {
    guard text != markedText else { return }
    markedText = text
    onMarkedTextChange(text.isEmpty ? nil : text)
  }

  var markedTextStyle: [NSAttributedString.Key: Any]?

  var markedTextRange: UITextRange? {
    markedText.isEmpty ? nil : OffsetRange(0, length)
  }

  var selectedTextRange: UITextRange? {
    get {
      guard !markedText.isEmpty else { return OffsetRange(0, 0) }
      let location = min(markedSelection.location, length)
      return OffsetRange(location, min(location + markedSelection.length, length))
    }
    // The selection lives in the marked text the input method owns; there
    // is no document to move a caret in.
    // swiftlint:disable:next unused_setter_value
    set {}
  }

  // MARK: - Document (the marked text only)

  private var length: Int { (markedText as NSString).length }

  func text(in range: UITextRange) -> String? {
    guard let range = range as? OffsetRange else { return nil }
    let lower = max(0, min(range.lower, length))
    let upper = max(lower, min(range.upper, length))
    return (markedText as NSString).substring(with: NSRange(location: lower, length: upper - lower))
  }

  func replace(_ range: UITextRange, withText text: String) {
    insertText(text)
  }

  var beginningOfDocument: UITextPosition { OffsetPosition(0) }
  var endOfDocument: UITextPosition { OffsetPosition(length) }

  func textRange(from fromPosition: UITextPosition, to toPosition: UITextPosition) -> UITextRange? {
    guard let from = fromPosition as? OffsetPosition, let to = toPosition as? OffsetPosition else { return nil }
    return OffsetRange(min(from.offset, to.offset), max(from.offset, to.offset))
  }

  func position(from position: UITextPosition, offset: Int) -> UITextPosition? {
    guard let position = position as? OffsetPosition else { return nil }
    let target = position.offset + offset
    return (0...length).contains(target) ? OffsetPosition(target) : nil
  }

  func position(from position: UITextPosition, in direction: UITextLayoutDirection, offset: Int) -> UITextPosition? {
    switch direction {
    case .left, .up: return self.position(from: position, offset: -offset)
    case .right, .down: return self.position(from: position, offset: offset)
    @unknown default: return nil
    }
  }

  func compare(_ position: UITextPosition, to other: UITextPosition) -> ComparisonResult {
    let lhs = (position as? OffsetPosition)?.offset ?? 0
    let rhs = (other as? OffsetPosition)?.offset ?? 0
    return lhs < rhs ? .orderedAscending : lhs > rhs ? .orderedDescending : .orderedSame
  }

  func offset(from: UITextPosition, to toPosition: UITextPosition) -> Int {
    ((toPosition as? OffsetPosition)?.offset ?? 0) - ((from as? OffsetPosition)?.offset ?? 0)
  }

  weak var inputDelegate: UITextInputDelegate?
  lazy var tokenizer: UITextInputTokenizer = UITextInputStringTokenizer(textInput: self)

  func position(within range: UITextRange, farthestIn direction: UITextLayoutDirection) -> UITextPosition? {
    guard let range = range as? OffsetRange else { return nil }
    switch direction {
    case .left, .up: return OffsetPosition(range.lower)
    case .right, .down: return OffsetPosition(range.upper)
    @unknown default: return nil
    }
  }

  func characterRange(byExtending position: UITextPosition, in direction: UITextLayoutDirection) -> UITextRange? {
    guard let position = position as? OffsetPosition else { return nil }
    switch direction {
    case .left, .up: return OffsetRange(0, position.offset)
    case .right, .down: return OffsetRange(position.offset, length)
    @unknown default: return nil
    }
  }

  func baseWritingDirection(for position: UITextPosition, in direction: UITextStorageDirection)
    -> NSWritingDirection
  { .leftToRight }

  func setBaseWritingDirection(_ writingDirection: NSWritingDirection, for range: UITextRange) {}

  /// Candidate windows anchor here: the bottom of the view, where the
  /// composition bubble floats.
  func firstRect(for range: UITextRange) -> CGRect {
    CGRect(x: bounds.midX, y: bounds.maxY - 1, width: 1, height: 1)
  }

  func caretRect(for position: UITextPosition) -> CGRect {
    CGRect(x: bounds.midX, y: bounds.maxY - 1, width: 1, height: 1)
  }

  func selectionRects(for range: UITextRange) -> [UITextSelectionRect] { [] }

  func closestPosition(to point: CGPoint) -> UITextPosition? { OffsetPosition(length) }

  func closestPosition(to point: CGPoint, within range: UITextRange) -> UITextPosition? {
    (range as? OffsetRange).map { OffsetPosition($0.upper) }
  }

  func characterRange(at point: CGPoint) -> UITextRange? { nil }

  // MARK: - Paste

  override func canPerformAction(_ action: Selector, withSender sender: Any?) -> Bool {
    action == #selector(paste(_:)) ? UIPasteboard.general.hasStrings : false
  }

  override func paste(_ sender: Any?) {
    guard let text = UIPasteboard.general.string, !text.isEmpty else { return }
    onPaste(text)
  }

  // MARK: - Hardware keys

  private var handledPresses: Set<ObjectIdentifier> = []
  private var repeatTimer: Timer?

  override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
    var forwarded = Set<UIPress>()
    for press in presses {
      guard let key = press.key, let action = keyAction(for: key) else {
        forwarded.insert(press)
        continue
      }
      handledPresses.insert(ObjectIdentifier(press))
      onKey(action.code, action.mods)
      if TerminalKeyMap.repeats(action.code) { startRepeat(action.code, action.mods) }
    }
    if !forwarded.isEmpty { super.pressesBegan(forwarded, with: event) }
  }

  override func pressesEnded(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
    super.pressesEnded(release(presses), with: event)
  }

  override func pressesCancelled(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
    super.pressesCancelled(release(presses), with: event)
  }

  /// Stops any repeat and returns the presses the text system owns.
  private func release(_ presses: Set<UIPress>) -> Set<UIPress> {
    stopRepeat()
    return presses.filter { handledPresses.remove(ObjectIdentifier($0)) == nil }
  }

  /// A held key's release goes to whoever is first responder by then, so
  /// losing focus or the window must end the repeat here; otherwise it
  /// would keep typing into the pane.
  override func resignFirstResponder() -> Bool {
    stopRepeat()
    handledPresses.removeAll()
    return super.resignFirstResponder()
  }

  override func didMoveToWindow() {
    super.didMoveToWindow()
    guard window == nil else { return }
    stopRepeat()
    handledPresses.removeAll()
  }

  var isRepeatingKey: Bool { repeatTimer != nil }

  private func stopRepeat() {
    repeatTimer?.invalidate()
    repeatTimer = nil
  }

  /// A hardware key this view sends itself, or nil to leave it to the text
  /// system: plain and shifted printable keys type text (so an input
  /// method can compose), a composition owns every key, and ⌘ chords are
  /// app shortcuts.
  func keyAction(for key: UIKey) -> (code: String, mods: IPC.TerminalKeyModifiers)? {
    guard markedText.isEmpty, let code = TerminalKeyMap.code(for: key.keyCode) else { return nil }
    let mods = TerminalKeyMap.modifiers(key.modifierFlags)
    guard !mods.super else { return nil }
    guard TerminalKeyMap.isNonTextKey(code) || mods.ctrl || mods.alt else { return nil }
    return (code, mods)
  }

  func startRepeat(_ code: String, _ mods: IPC.TerminalKeyModifiers) {
    repeatTimer?.invalidate()
    // Hardware presses do not repeat on iOS; do it like a Mac would.
    repeatTimer = Timer.scheduledTimer(withTimeInterval: 0.42, repeats: false) { [weak self] _ in
      MainActor.assumeIsolated {
        self?.repeatTimer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
          MainActor.assumeIsolated { self?.onKey(code, mods) }
        }
      }
    }
  }

  override var keyCommands: [UIKeyCommand]? {
    var commands = [
      command("[", .command, "Previous Pane", #selector(previousPane)),
      command("]", .command, "Next Pane", #selector(nextPane)),
      command("t", .command, "New Tab", #selector(newTab)),
      command("d", .command, "Split Right", #selector(splitRight)),
      command("d", [.command, .shift], "Split Down", #selector(splitDown)),
      command("=", .command, "Zoom In", #selector(zoomIn)),
      command("+", .command, "Zoom In", #selector(zoomIn)),
      command("-", .command, "Zoom Out", #selector(zoomOut)),
      command("k", .command, "Clear", #selector(clear)),
    ]
    for index in 1...9 {
      commands.append(command("\(index)", .command, "Tab \(index)", #selector(selectTab(_:))))
    }
    return commands
  }

  private func command(_ input: String, _ flags: UIKeyModifierFlags, _ title: String, _ action: Selector)
    -> UIKeyCommand
  {
    let command = UIKeyCommand(title: title, action: action, input: input, modifierFlags: flags)
    command.wantsPriorityOverSystemBehavior = true
    return command
  }

  @objc private func previousPane() { onShortcut(.previousPane) }
  @objc private func nextPane() { onShortcut(.nextPane) }
  @objc private func newTab() { onShortcut(.newTab) }
  @objc private func splitRight() { onShortcut(.splitRight) }
  @objc private func splitDown() { onShortcut(.splitDown) }
  @objc private func zoomIn() { onShortcut(.zoomIn) }
  @objc private func zoomOut() { onShortcut(.zoomOut) }
  @objc private func clear() { onShortcut(.clear) }
  @objc private func selectTab(_ command: UIKeyCommand) {
    guard let index = command.input.flatMap(Int.init) else { return }
    onShortcut(.tab(index))
  }
}

private final class OffsetPosition: UITextPosition {
  let offset: Int
  init(_ offset: Int) { self.offset = offset }
}

private final class OffsetRange: UITextRange {
  let lower: Int
  let upper: Int

  init(_ lower: Int, _ upper: Int) {
    self.lower = lower
    self.upper = upper
  }

  override var start: UITextPosition { OffsetPosition(lower) }
  override var end: UITextPosition { OffsetPosition(upper) }
  override var isEmpty: Bool { lower == upper }
}

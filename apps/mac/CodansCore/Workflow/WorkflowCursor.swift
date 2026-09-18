import Foundation

/// Where the machine stands in the step tree. A stack of frames: the root
/// frame walks the top-level steps, and each `while` the run is inside
/// pushes a frame over that loop's body with its iteration counter. The
/// cursor only knows positions; the definition it indexes is the run's,
/// so it stays a small value that the record can describe.
public nonisolated struct WorkflowCursor: Equatable, Sendable {
  public struct Frame: Equatable, Sendable {
    /// Indices from the root step list down to the loop step this frame
    /// walks the body of; empty for the root frame.
    public var path: [Int]
    /// Index of the current step within the frame's step list; equal to
    /// the list's count once the frame is exhausted.
    public var index: Int
    /// 1-based iteration for loop frames, 0 for the root.
    public var iteration: Int

    public init(path: [Int], index: Int = 0, iteration: Int = 0) {
      self.path = path
      self.index = index
      self.iteration = iteration
    }

    public var isLoop: Bool { !path.isEmpty }
  }

  public var frames: [Frame]

  public init() {
    frames = [Frame(path: [])]
  }

  public var depth: Int { frames.count }

  public var isInLoop: Bool { frames.count > 1 }

  /// Iteration of the innermost loop, `nil` at the root.
  public var iteration: Int? {
    guard let top = frames.last, top.isLoop else { return nil }
    return top.iteration
  }

  // MARK: - Resolution against a definition

  /// The step list a frame walks.
  public func steps(of frame: Frame, in definition: WorkflowDefinition) -> [WorkflowStep] {
    var steps = definition.steps
    for index in frame.path {
      guard steps.indices.contains(index), case .loop(_, _, let body) = steps[index].verb else { return [] }
      steps = body
    }
    return steps
  }

  /// The loop step a loop frame is the body of.
  public func loopStep(of frame: Frame, in definition: WorkflowDefinition) -> WorkflowStep? {
    guard let last = frame.path.last else { return nil }
    let parent = Frame(path: Array(frame.path.dropLast()))
    let siblings = steps(of: parent, in: definition)
    return siblings.indices.contains(last) ? siblings[last] : nil
  }

  /// The step under the cursor, `nil` when the innermost frame is
  /// exhausted (its loop body or the whole run has run out of steps).
  public func currentStep(in definition: WorkflowDefinition) -> WorkflowStep? {
    guard let top = frames.last else { return nil }
    let list = steps(of: top, in: definition)
    return list.indices.contains(top.index) ? list[top.index] : nil
  }

  /// The innermost loop step the cursor is inside, `nil` at the root.
  public func enclosingLoop(in definition: WorkflowDefinition) -> WorkflowStep? {
    guard let top = frames.last, top.isLoop else { return nil }
    return loopStep(of: top, in: definition)
  }

  /// Every loop step the cursor is inside, outermost first.
  public func enclosingLoops(in definition: WorkflowDefinition) -> [WorkflowStep] {
    frames.dropFirst().compactMap { loopStep(of: $0, in: definition) }
  }

  // MARK: - Movement

  /// Moves past the current step within the innermost frame.
  public mutating func advance() {
    guard !frames.isEmpty else { return }
    frames[frames.count - 1].index += 1
  }

  /// Pushes a frame over the current step's body, which must be a loop.
  public mutating func enterLoop() {
    guard let top = frames.last else { return }
    frames.append(Frame(path: top.path + [top.index], index: 0, iteration: 1))
  }

  /// Rewinds the innermost loop body for its next pass.
  public mutating func nextIteration() {
    guard frames.count > 1 else { return }
    frames[frames.count - 1].index = 0
    frames[frames.count - 1].iteration += 1
  }

  /// Pops the innermost loop frame and steps past the loop in its parent.
  public mutating func exitLoop() {
    guard frames.count > 1 else { return }
    frames.removeLast()
    advance()
  }

  /// Steps the innermost frame to its end so the next check sees it as
  /// exhausted (a `continue`).
  public mutating func finishBody(in definition: WorkflowDefinition) {
    guard let top = frames.last, top.isLoop else { return }
    frames[frames.count - 1].index = steps(of: top, in: definition).count
  }
}

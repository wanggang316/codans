import SwiftUI

extension EnvironmentValues {
  /// The app's workflow engine, for views outside the TCA tree that show or
  /// act on runs (the toolbar's workflow group, the Workflow Runs window).
  /// `nil` in previews and before the app finishes bringing up.
  @Entry var workflowEngine: WorkflowEngine?
}

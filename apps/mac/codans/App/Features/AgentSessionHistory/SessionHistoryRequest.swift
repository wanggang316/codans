import CodansCore
import SwiftUI

/// A request to toggle the Session History popover, sent by the ⌘Y menu
/// command through `RootFeature.sessionHistoryToggle`.
///
/// The popover's presentation is view state on its anchor, so the request
/// only names the target: a pane opens it on its actions button, and `nil`
/// opens it on the empty page of a worktree that has no tab. Each press has
/// a new `serial`, so the anchor sees a change even when the target repeats.
struct SessionHistoryRequest: Equatable, Sendable {
  let paneID: PaneID?
  let serial: Int
}

private struct SessionHistoryRequestKey: EnvironmentKey {
  static let defaultValue: SessionHistoryRequest? = nil
}

extension EnvironmentValues {
  var sessionHistoryRequest: SessionHistoryRequest? {
    get { self[SessionHistoryRequestKey.self] }
    set { self[SessionHistoryRequestKey.self] = newValue }
  }
}

extension View {
  /// Toggles `isPresented` each time a new request names `target`.
  func onSessionHistoryRequest(for target: PaneID?, isPresented: Binding<Bool>) -> some View {
    modifier(SessionHistoryRequestReceiver(target: target, isPresented: isPresented))
  }
}

private struct SessionHistoryRequestReceiver: ViewModifier {
  let target: PaneID?
  @Binding var isPresented: Bool

  @Environment(\.sessionHistoryRequest) private var request

  func body(content: Content) -> some View {
    content.onChange(of: request) { _, request in
      guard let request, request.paneID == target else { return }
      isPresented.toggle()
    }
  }
}

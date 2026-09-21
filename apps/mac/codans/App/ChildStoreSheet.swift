import ComposableArchitecture
import SwiftUI

/// Presents an optional child store as a sheet, without the blank card a
/// sheet flashes on its way out.
///
/// A sheet whose content is `if let child = store.scope(state: \.optional,
/// …)` loses that content the instant the state is cleared — which happens
/// before the dismissal animation runs, so the window shrinks around an
/// empty view and reads as a blank rounded card. Holding the last scoped
/// store lets the sheet fade out as itself; TCA's `IfLetCore` keeps serving
/// the child's final state (`base.state[keyPath:] ?? cachedState`), so the
/// closing view is never reading a dead store.
///
/// Features that model presentation with `@Presents` don't need this:
/// `sheet(item: $store.scope(…))` already hands the closing sheet its
/// store. This is for the plain-optional child state the sidebar uses.
struct ChildStoreSheet<ChildState, ChildAction, SheetContent: View>: ViewModifier {
  /// The child while it is presented; nil once the feature dismissed it.
  let child: Store<ChildState, ChildAction>?
  /// Sent when the system dismisses the sheet (Esc, or a click outside).
  let onDismiss: () -> Void
  @ViewBuilder let sheetContent: (Store<ChildState, ChildAction>) -> SheetContent

  /// The store the sheet keeps rendering while it animates away.
  @State private var closing: Store<ChildState, ChildAction>?

  func body(content: Content) -> some View {
    content
      .sheet(
        isPresented: Binding(
          get: { child != nil },
          set: { isPresented in
            if !isPresented { onDismiss() }
          }
        )
      ) {
        if let presented = child ?? closing {
          sheetContent(presented)
        }
      }
      .onChange(of: child.map(ObjectIdentifier.init)) { _, _ in
        if let child { closing = child }
      }
  }
}

extension View {
  /// Presents `child` as a sheet that keeps its content through the
  /// dismissal animation. See `ChildStoreSheet`.
  func childSheet<ChildState, ChildAction, SheetContent: View>(
    _ child: Store<ChildState, ChildAction>?,
    onDismiss: @escaping () -> Void,
    @ViewBuilder content: @escaping (Store<ChildState, ChildAction>) -> SheetContent
  ) -> some View {
    modifier(ChildStoreSheet(child: child, onDismiss: onDismiss, sheetContent: content))
  }
}

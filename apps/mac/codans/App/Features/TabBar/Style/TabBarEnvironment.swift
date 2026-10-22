import SwiftUI

extension EnvironmentValues {
  /// Whether the enclosing tab strip renders its active style: its Pane is
  /// the focused one and its window is key. `false` switches the chips to
  /// the inactive-window tokens in `TabBarColors`.
  @Entry var tabStripIsActive: Bool = true
}

import Carbon.HIToolbox
import CodansCore
import Testing

@testable import Codans

@MainActor
struct SidebarToggleButtonTests {
  @Test
  func defaultTooltipNamesTheActionAndTheDefaultChord() {
    let shortcuts = ShortcutResolver.resolve(overrides: .empty)
    #expect(SidebarToggleButton.tooltip(isSidebarVisible: true, shortcuts: shortcuts) == "Hide Sidebar \u{2318} /")
    #expect(SidebarToggleButton.tooltip(isSidebarVisible: false, shortcuts: shortcuts) == "Show Sidebar \u{2318} /")
  }

  @Test
  func tooltipFollowsARebind() {
    let shortcuts: ResolvedShortcutMap = [
      .toggleSidebar: ResolvedShortcut(
        id: .toggleSidebar,
        binding: ShortcutBinding(keyCode: UInt16(kVK_ANSI_B), modifiers: [.command, .control]),
        isEnabled: true,
        source: .userOverride
      )
    ]
    #expect(
      SidebarToggleButton.tooltip(isSidebarVisible: true, shortcuts: shortcuts) == "Hide Sidebar \u{2303} \u{2318} B")
  }

  @Test
  func clearedBindingShowsTheTitleOnly() {
    let shortcuts: ResolvedShortcutMap = [
      .toggleSidebar: ResolvedShortcut(id: .toggleSidebar, binding: nil, isEnabled: true, source: .userOverride)
    ]
    #expect(SidebarToggleButton.tooltip(isSidebarVisible: false, shortcuts: shortcuts) == "Show Sidebar")
  }
}

# Lessons Learned: an accessibility label on selectable text crashed the app under an AX client

**Status:** Resolved
**Date:** 2026-11-09
**Area:** Settings → Agents profile detail (`AgentProfileDetailView`)
**Fix:** issue #470 — `fix(settings): stop the AX label recursion on the agent launch preview`

## Summary

The Debug app crashed with SIGSEGV (stack guard) when an accessibility
client walked the detail screen of any agent profile, new or existing. A
Release build with VoiceOver on can crash the same way. The crash happens
when the client reaches the Launch Preview command text.

## Root cause

The command text had both `.textSelection(.enabled)` and
`.accessibilityLabel("Launch command")`:

```swift
Text(AgentLaunchCommand.render(profile: profile))
  .textSelection(.enabled)
  .accessibilityLabel("Launch command")
```

With text selection enabled, the SwiftUI accessibility node of the `Text`
has an AppKit platform element. To resolve the custom label, the node asks
for its role (`labelsToResolve` → `labelExposedAs` → `resolvedRole`), and
the role lookup reads an attribute from the platform element. AppKit sends
that read back to the same node's `accessibilityLabel()`. The cycle repeats
until the main thread stack overflows.

Top recursive frames from the crash log:

```text
AppKit  _accessibilityFindRoleFromProtocol
AppKit  NSAccessibilityGetObjectValueForAttribute
SwiftUI PlatformAccessibilityElementProtocol<>.valueForAttribute<A>(_:asType:)
SwiftUI AccessibilityNode.resolvedRole(forPlatformElement:)
SwiftUI AccessibilityNode.labelExposedAs.getter
SwiftUI AccessibilityNode.labelsToResolve.getter
SwiftUI AccessibilityNode.accessibilityLabel()
SwiftUI closure #4 in AccessibilityNode.applyProperties(to:)
AppKit  _accessibilityGetAssociatedObjectForAttribute
AppKit  NSAccessibilityGetObjectValueForAttribute
...
SwiftUI AccessibilityNode.accessibilityLabel()
```

Making the text its own element (`.accessibilityElement(children: .ignore)`
plus label and value) is not enough. The walk then completes, but the app
still crashes a moment later, because the node keeps the same platform
element.

## Fix

The label moved to a plain SwiftUI container around the text. The
selectable `Text` has no accessibility modifiers:

```swift
HStack {
  Text(command).textSelection(.enabled)
  Spacer(minLength: 0)
}
.accessibilityElement(children: .contain)
.accessibilityLabel("Launch command")
```

VoiceOver reads an `AXGroup "Launch command"` that contains the command
text. All other labels on the pane are unchanged.

## Recurrence checks

- Do not put accessibility modifiers (`.accessibilityLabel`,
  `.accessibilityElement`, `.accessibilityValue`, ...) on a view that has
  `.textSelection(.enabled)`. Put them on a container.
  `grep -rn -A4 'textSelection(.enabled)' apps/mac/codans | grep accessibility`
  must print nothing.
- To check a pane, walk its full AX tree on an isolated Debug instance
  (`sv_tree` in the self-verify skill), wait a few seconds, then confirm
  that the instance is still alive and that no new
  `~/Library/Logs/DiagnosticReports/Codans-*.ips` exists. A complete tree
  output alone does not prove the absence of the crash.

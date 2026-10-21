---
status: accepted
---

# Content runtime lives outside HierarchyManager

Live content state (surfaces, busy / progress / badge flags, renderers) is owned by a `ContentRuntime` registry keyed by ContentID, with one `TabChrome` observable per content for strip-facing state and a `TabContent` protocol per content kind. `HierarchyManager` owns catalog mutation and structural runtime state (focus, selection) only. Adding a content kind means one `TabContent` implementation plus registration, with no change to the shared layout layer.

## Considered options

- Keep runtime maps (`runningTabs`, `commandBusyTabs`, surfaces) on `HierarchyManager`, re-keyed by ContentID. Smaller first change, but every new content kind would grow the hierarchy manager, and the layout layer would know terminal specifics.

## Consequences

- `TerminalContent` wraps the libghostty surface lifecycle that `TerminalEngine` provides today.
- `AgentStateStore`, `SurfaceReclaimPolicy`, and the notification inbox key on ContentID and stay separate stores.

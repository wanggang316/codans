# Development traps

Constraints that the code does not show and that break the build, a test, or the accessibility tree when a change ignores them. Each one was recorded when the problem occurred. The Swift and Xcode versions change: if a trap does not reproduce, remove it.

For the build commands, see [AGENTS.md](../../AGENTS.md#quick-start). For the build invariants of the toolchain, see [Architecture](../architecture.md#build-and-toolchain).

## Swift

- Use `@Dependency(Type.self)`, not the key path form. `WritableKeyPath` is not `Sendable`.
- Erase a recursive SwiftUI view with `AnyView`. Without it the type checker can run for more than five minutes.
- Write `CodansCore.Tab` in full. `SwiftUI.Tab` shadows it.
- The app target is MainActor by default. See the MainActor rule in [Architecture](../architecture.md#cross-module-invariants).

## Tests

- In a `@Test`, `String.split(whereSeparator:)` with `String.Index` slicing can crash (signal 5, `dispatch_assert_queue_fail`). Use `components(separatedBy:)` and slice the UTF-8 view.
- Run `xcodebuild` on `codans.xcworkspace`, not with `-project`. The Swift packages resolve at the workspace level.
- `make mac-test` runs the `Codans`, `CodansCore`, and `CodansKit` schemes. To examine one failure, select its scheme.
- `xcodebuild test ENV=value` sets a build setting, not an environment variable of the test process. Gate an integration or performance test with `.enabled(if:)` that reads `ProcessInfo`. A thrown skip counts as a failure.

## Accessibility values that tests and probes read

Accessibility values that the user can observe are a probe contract: validation reads them, and a renamed value breaks a test. `AgentStateRowView` and `PendingWorktreeRow` are the examples to copy.

- `.accessibilityValue(_:)` on a view that is also `.accessibilityElement(children: .contain)` has no effect. The container exposes its children, not its own value. Put the value on a leaf child.
- `.accessibilityLabel(_:)`, `.accessibilityAddTraits(.isButton)`, and `.accessibilityAction(.default)` on a `.contain` group do reach the accessibility tree.
- `.accessibilityRepresentation { … }` replaces the accessibility of the whole subtree, so it hides the leaves. Use it only for an element with no children to probe.
- A `Button` merges the texts of its label into one element. A row whose leaves must stay separate cannot be a `Button`: use a `.contain` group with `onTapGesture`, the button trait, the default action, and `.focusable(interactions: .activate)` with `onKeyPress` for Space and Return.
- Hide decorative spinners and glyphs with `.accessibilityHidden(true)`. The value or the label carries the meaning.
- Do not put an accessibility label on text with `.textSelection(.enabled)`. See [AX label on selectable text recursed](../lessons-learned/2026-11-09-ax-label-on-selectable-text-recursed.md).

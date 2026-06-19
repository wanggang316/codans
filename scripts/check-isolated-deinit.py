#!/usr/bin/env python3
"""Guard against Swift 6 isolated-deinit landmines in the MainActor-default app target.

The macOS app target builds with `SWIFT_DEFAULT_ACTOR_ISOLATION=MainActor`
(see apps/mac/Project.swift), so every class WITHOUT an explicit `deinit` gets a
compiler-synthesized *isolated* deinit. When such an object is released inside a
cascading teardown -- e.g. a SwiftUI transaction flush that tears a view subtree
down -- the isolated deinit hops via `swift_task_deinitOnExecutorMainActorBackDeploy`
and double-frees a TaskLocal `StopLookupScope`, aborting in libmalloc
("pointer being freed was not allocated").

This has bitten the codebase repeatedly: PaneSurface, PendingOutputBuffer,
SurfaceInfo, GhosttySurfaceView.CachedValue, and AgentStateOrderCoordinator. The
fix is always the same -- declare an explicit (nonisolated) `deinit`.

This guard flags the highest-signal subset: a class that *stores* an unstructured
`Task` property but declares no explicit `deinit`. That combination is both the
strongest crash vector and a likely task leak (you almost always want to cancel
the task in deinit). New violations fail; a documented baseline of pre-existing,
reviewed-safe app-level singletons is allowed through.

Usage: check-isolated-deinit.py <app-target-source-dir>
"""

import os
import re
import sys

# Pre-existing classes that store a Task without an explicit deinit but are
# app-level singletons: they are deallocated only at process teardown, never
# inside a SwiftUI/observation cascade, so they cannot hit the double-free.
# Each should eventually grow an explicit deinit too; until then they are
# baselined so the guard can enforce the rule on NEW code. Key: "relpath::Class".
BASELINE = {
    "App/CodansApp.swift::AppState",
    "App/Features/Notifications/NotificationStore.swift::NotificationStore",
    "App/Features/Notifications/RollupIndexProvider.swift::RollupIndexProvider",
    "App/Features/Settings/SettingsStore.swift::SettingsStore",
    "Runtime/CatalogStore.swift::CatalogStore",
}

# Strip `//` line comments and `/* */` block comments so prose like
# "... the class is ..." in doc comments never reads as a declaration.
_LINE_COMMENT = re.compile(r"//[^\n]*")
_BLOCK_COMMENT = re.compile(r"/\*.*?\*/", re.DOTALL)
_CLASS_DECL = re.compile(r"\bclass\s+([A-Za-z_]\w*)")
_STORED_TASK = re.compile(r"\b(?:var|let)\s+(\w+)\s*:\s*Task\s*<")


def strip_comments(src: str) -> str:
    return _LINE_COMMENT.sub("", _BLOCK_COMMENT.sub("", src))


def class_body(src: str, open_brace: int) -> str:
    """Return the text between the class's `{` and its matching `}`."""
    depth = 0
    for i in range(open_brace, len(src)):
        c = src[i]
        if c == "{":
            depth += 1
        elif c == "}":
            depth -= 1
            if depth == 0:
                return src[open_brace + 1 : i]
    return src[open_brace + 1 :]


def direct_members(body: str) -> str:
    """Text of the class body at brace-depth 0 only (immediate members), so a
    nested type's `deinit` / `Task` property is not attributed to the outer class."""
    out, depth = [], 0
    for c in body:
        if c == "{":
            depth += 1
            continue
        if c == "}":
            depth -= 1
            continue
        if depth == 0:
            out.append(c)
    return "".join(out)


def violations_in(path: str, relpath: str):
    src = strip_comments(open(path, encoding="utf-8").read())
    found = []
    for m in _CLASS_DECL.finditer(src):
        name = m.group(1)
        # `nonisolated` opts the class out of MainActor isolation -> nonisolated
        # deinit -> no executor hop. Look just before the `class` keyword.
        prefix = src[max(0, m.start() - 60) : m.start()]
        if re.search(r"\bnonisolated\b", prefix):
            continue
        brace = src.find("{", m.end())
        if brace < 0:
            continue
        members = direct_members(class_body(src, brace))
        tasks = _STORED_TASK.findall(members)
        if not tasks:
            continue
        if re.search(r"\bdeinit\b", members):
            continue
        found.append((name, tasks))
    return found


def main() -> int:
    if len(sys.argv) != 2:
        print("usage: check-isolated-deinit.py <app-target-source-dir>", file=sys.stderr)
        return 2
    root = sys.argv[1]
    if not os.path.isdir(root):
        print(f"error: not a directory: {root}", file=sys.stderr)
        return 2

    offenders = []
    for dirpath, _, files in os.walk(root):
        if os.sep + "Tests" in os.sep + dirpath + os.sep:
            continue
        for f in files:
            if not f.endswith(".swift"):
                continue
            path = os.path.join(dirpath, f)
            rel = os.path.relpath(path, root)
            for name, tasks in violations_in(path, rel):
                key = f"{rel}::{name}"
                if key in BASELINE:
                    continue
                offenders.append((key, tasks))

    if offenders:
        print("isolated-deinit guard: FAIL\n", file=sys.stderr)
        print(
            "These @MainActor classes store a Task but have no explicit `deinit`, so\n"
            "Swift 6 synthesizes an *isolated* deinit that can double-free during a\n"
            "cascading teardown (libmalloc abort). Add an explicit deinit, e.g.:\n\n"
            "    deinit { myTask?.cancel() }\n\n"
            "(`Task.cancel()` is nonisolated and `Task?` is Sendable, so it is sound\n"
            "from a nonisolated deinit.) See scripts/check-isolated-deinit.py header.\n",
            file=sys.stderr,
        )
        for key, tasks in offenders:
            print(f"  {key}  (stored task: {', '.join(tasks)})", file=sys.stderr)
        return 1

    print("isolated-deinit guard: OK")
    return 0


if __name__ == "__main__":
    sys.exit(main())

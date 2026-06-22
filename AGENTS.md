# codans

## Quick Start

```bash
# One-time per worktree (fresh clone or `git worktree add`)
mise trust . apps/mac                           # trust mise config for this + apps/mac cwd
make bootstrap                                  # init submodules (ghostty, git-wt) + mise install (tuist/zig/swiftlint/xcbeautify/xcsift)

# Build / run
make mac-generate                               # tuist install + tuist generate (transitively builds Ghostty xcframework)
make mac-build                                  # build codans.app + codans CLI
make mac-run-app                                # build + open the app

# Code hygiene
make mac-lint                                   # swiftlint --quiet
make mac-check                                  # swift-format in-place + lint
```

Multi-worktree tip: `ln -s <main>/apps/mac/.build/ghostty apps/mac/.build/ghostty` avoids re-compiling Ghostty (~3.9 GB, ~20 min first time) in every new worktree. `build-ghostty.sh` primes Zig's cache via curl automatically (Zig 0.15.2's TLS handshake is rejected by Cloudflare on `deps.files.ghostty.org`; the prime step is idempotent and a no-op on cache hits).

Requires Xcode **26.0+** (pinned via `apps/mac/Tuist.swift: compatibleXcodeVersions: .upToNextMajor("26.0")`).

## Architecture Overview

codans is a native macOS app that orchestrates terminals into a four-level hierarchy (Project → Worktree → Tab → Pane) for CLI-agent power users. It ships three co-versioned artifacts — the Mac app, the `codans` CLI, and a published Agent Skill — out of a Tuist-managed monorepo. The runtime is Swift 6 with hybrid TCA + `@Observable`, libghostty embedded via submodule, and JSON-RPC over a Unix socket between app and CLI. Architecture is adapted from the user's reference projects **supacode** and **supaterm**.

See [Architecture](docs/architecture.md) for domains, layers, and dependency rules.

## Repository Structure

```
codans/
├── apps/mac/                   # Mac platform: Tuist project, sources, ghostty submodule
│   ├── codans/                 # The Mac app (App / Runtime / Hooks / Process / Git / GitHub)
│   ├── codans-cli/             # `codans` CLI binary (RPC client to the running app)
│   ├── CodansKit/              # CLI-side library shared by codans-cli + tests
│   ├── CodansCore/          # Pure domain models (Project / Worktree / Tab / Pane / Tag)
│   ├── CodansIPC/           # JSON-RPC wire protocol shared by app + CLI
│   ├── ThirdParty/ghostty/     # libghostty submodule (built into GhosttyKit.xcframework)
│   ├── Project.swift           # Tuist project definition
│   └── Makefile                # Mac-platform build targets
├── docs/                       # Project documentation (architecture, specs, design, plans)
├── skills/                     # Published Agent Skill content (text-only, no engineering coupling)
├── scripts/                    # Repo-wide scripts
├── mise.toml                   # Pinned tool versions (tuist / zig / swiftlint / xcbeautify)
├── Makefile                    # Top-level delegator → apps/mac/Makefile
└── .github/workflows/          # CI workflows
```

## Golden Rules


1. **AGENTS.md is a map, not a manual** — keep this file under 150 lines
2. **Validate boundaries** — parse and validate data at system edges, never probe
3. **Prefer shared utilities** — centralize invariants, avoid hand-rolled duplicates
4. **Every complex change gets an execution plan** — plan before building
5. **Fix the environment, not the prompt** — when agents struggle, add missing tools/docs/guardrails

See [Golden Rules](docs/golden-rules.md) for the complete list with rationale and enforcement.

## Documentation


| Directory | Purpose |
|---|---|
| [docs/architecture.md](docs/architecture.md) | System architecture, domains, layers |
| [docs/golden-rules.md](docs/golden-rules.md) | Enforced principles and conventions |
| [docs/design-docs/](docs/design-docs/) | Design documents |
| [docs/product-specs/](docs/product-specs/) | Product specifications |
| [docs/references/](docs/references/) | External docs, API references |
| [docs/generated/](docs/generated/) | Auto-generated artifacts |

## Working with This Repository


- Before making changes, read the relevant docs for the area you're touching
- For complex work, create an execution plan before starting
- Run lint and tests before submitting PRs
- Follow the dependency rules in architecture docs
- When something fails, ask: "What capability is missing?" — then add it

## Build & Test Commands

See [Quick Start](#quick-start). Top-level Makefile delegates every `mac-*` target to `apps/mac/Makefile`. Run `make help` for the full list.

## Code Style & Conventions

- **Language:** Swift 6 with strict concurrency. Targets are wired via Tuist; do not edit the generated `.xcodeproj`/`.xcworkspace` directly.
- **Lint / format:** `swiftlint` (config `apps/mac/.swiftlint.yml`, `strict: true`) and `swift-format` (config `apps/mac/.swift-format.json`). Run `make mac-check` before committing.
- **Architecture:** hybrid TCA + `@Observable`. Domain types live in `CodansCore`; wire protocol in `CodansIPC`; app features under `apps/mac/codans/App/Features/<Feature>/`.
- **Module boundaries** (`Runtime`, `Hooks`, `Git`, `GitHub`, `App`) are enforced by folder convention + code review, not Tuist target edges. Do not add cross-module imports that bypass the documented boundary.
- **Subprocess:** always go through the shared `CommandRunner` in `apps/mac/codans/Process/`. Do not spawn `Process` directly inside feature modules.
- **Naming:** Swift API Design Guidelines. Filenames match the primary type. TCA reducers end with `Feature`, views with `View`.
- **Comments:** explain *why*, not *what*. Cite design-doc IDs when a non-obvious decision is encoded in code.

# Git fixture tree — placeholder for 0005 M4b / M8

This directory is reserved for on-disk fixtures that will replace the currently-embedded
Swift string literals in `codans/Tests/GitTests/`:

- `diff-*.txt` — unified-diff samples covering every `FileChange.Kind` branch. See 0005 M2
  plan and `DiffParserTests.swift` for the per-branch list.
- `log-*.txt` — null-delimited `git log` samples (linear, merge, root, UTF-8 authors).
- `status-*.txt` — `git status --porcelain=v1 -z` samples.
- `diff-too-large.txt` — 50 001-line fixture for the `GitError.diffTooLarge` boundary.

## Why on-disk now?

The fixtures are currently embedded as Swift multiline strings inside `DiffParserTests` and
`GitOutputParserTests`. That works for small fixtures but is awkward for the 50 001-line case
(generated programmatically today) and doesn't survive cross-pollination with a Swift
Testing `Fixtures/` folder convention we adopt in 0005 M4b for snapshot references.

## Loading convention (to be used by M4b + M8 test files)

Fixtures will be loaded via `Bundle.module` once this folder is wired into a `.unitTests`
target's resources list. Until then the directory is a placeholder — no Swift code reads
from it. The directory ships empty so the Tuist regenerate step picks up the tree without
any build-product surprise.

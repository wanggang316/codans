# Homebrew release pipeline

`codans` ships to Homebrew through a self-hosted cask in **`wanggang316/homebrew-tap`**. Stable installs run as:

```bash
brew install --cask wanggang316/tap/codans
```

## Pipeline

1. `release.yml` cuts a notarized `Codans-<version>.dmg` + `.sha256` and attaches them to a **draft** GitHub Release. Manual review / publication remains the safety gate.
2. When the maintainer flips the release to **published**, `update-cask.yml` fires on the `release: published` event.
3. The workflow downloads the DMG asset, cross-checks the published `.sha256` against a fresh `shasum -a 256` of the downloaded bytes, then runs `scripts/render-cask.sh` against the in-repo template at `Casks/codans.rb`.
4. The rendered cask is pushed as a single commit to `wanggang316/homebrew-tap` at `Casks/codans.rb` over HTTPS using `HOMEBREW_TAP_TOKEN`.

`tip`-channel releases (`release-tip.yml`) are tagged `tip` and marked prerelease — `update-cask.yml` filters both out so Homebrew users stay on the stable channel. Sparkle still handles in-app tip-channel updates for opted-in clients.

## One-time bootstrap

These steps are required exactly once per environment; future stable releases are fully hands-off.

1. **Create the tap repo.** Empty repo, default branch `main`:

   ```bash
   gh repo create wanggang316/homebrew-tap --public --description "Homebrew tap for wanggang316 projects"
   ```

2. **Mint a Personal Access Token.** Fine-grained PAT scoped to the tap repo with `Contents: Read and write` is sufficient; a classic PAT with `repo` works too. Store the value somewhere durable — GitHub does not let you re-read it.

3. **Register the token on this repo:**

   ```bash
   gh secret set HOMEBREW_TAP_TOKEN --repo wanggang316/codans --body "$PAT_VALUE"
   ```

   The workflow refuses to run without it (see the `: "${TAP_TOKEN:?…}"` guard).

4. **First-time cask seed.** The very first stable release after enabling this pipeline writes the initial `Casks/codans.rb` into the empty tap repo. No manual seeding required.

## Local dry-run

Render the cask against an existing DMG without touching CI or the tap:

```bash
DMG=apps/mac/.build/release/Codans-0.3.0.dmg
SHA=$(shasum -a 256 "$DMG" | awk '{print $1}')
./scripts/render-cask.sh 0.3.0 "$SHA" /tmp/codans.rb
brew style /tmp/codans.rb            # optional: run Homebrew's rubocop
brew install --cask /tmp/codans.rb   # optional: smoke-test the install
```

## Troubleshooting

- **`brew install` fails with `Cask 'codans' is unavailable`** — the user forgot to tap. Both `brew install --cask wanggang316/tap/codans` and `brew tap wanggang316/tap && brew install --cask codans` work; the former is the recommended one-liner.
- **Workflow exits "cask already at v… in tap — nothing to push"** — the rendered cask matched the tap copy byte-for-byte. Usually means the workflow was re-run after a successful push; harmless.
- **`sha256 mismatch`** — the DMG attached to the Release does not match its `.sha256` sidecar. Indicates a corrupted or swapped asset. Re-run `release.yml` against the same tag and re-publish.
- **Tap push 403** — `HOMEBREW_TAP_TOKEN` expired or lacks `contents:write` on the tap repo. Rotate the PAT and `gh secret set` it again.

## Future: official `homebrew-cask`

If codans grows enough adoption to meet Homebrew's [acceptable casks criteria](https://docs.brew.sh/Acceptable-Casks), we can mirror the same `Casks/codans.rb` into a PR against `Homebrew/homebrew-cask`. The cask is already structured to pass `brew style` and `brew audit --new`. Until then, the self-hosted tap is the canonical channel.

# Homebrew cask

codans ships to Homebrew through a self-hosted cask in **`wanggang316/homebrew-tap`**. Users install it with:

```bash
brew install --cask wanggang316/tap/codans
```

Each published stable release updates the cask with no manual step: `release-merge.yml` calls `update-cask.yml`, which checks the DMG against its `.sha256`, renders `Casks/codans.rb` with `scripts/render-cask.sh`, and pushes it to the tap. `tip` and other prereleases never reach the cask. How this step fits in the pipeline: [Updates and release](../domains/updates-and-release.md#stable-release).

## Prerequisites (one time)

1. **Create the tap repository.** Empty, default branch `main`:

   ```bash
   gh repo create wanggang316/homebrew-tap --public --description "Homebrew tap for wanggang316 projects"
   ```

2. **Create a Personal Access Token.** A fine-grained PAT for the tap repository with `Contents: Read and write` is sufficient; a classic PAT with `repo` also works. Store the value: GitHub does not show it again.

3. **Register the token on this repository:**

   ```bash
   gh secret set HOMEBREW_TAP_TOKEN --repo wanggang316/codans --body "$PAT_VALUE"
   ```

   The workflow stops without it.

The first stable release after this writes `Casks/codans.rb` into the empty tap. No manual seed is necessary.

## Update the cask by hand

Use this when the `cask` job of a release run failed, or a release was published without it:

```bash
gh workflow run update-cask.yml -f tag=vX.Y.Z
```

The tag must be a published `vX.Y.Z` release. To repeat only the failed job of a release run, use `gh run rerun <RUN> --failed`.

## Check the result

1. The `update-cask` job ends green, with a `codans X.Y.Z` commit in the tap, or with the notice that the tap already has this or a newer version.
2. `Casks/codans.rb` in the tap shows `version "X.Y.Z"` and the hash of the published DMG.
3. `brew update && brew info --cask wanggang316/tap/codans` shows the new version.

## Local dry run

Render the cask against an existing DMG without CI or the tap:

```bash
DMG=apps/mac/.build/release/Codans-0.3.0.dmg
SHA=$(shasum -a 256 "$DMG" | awk '{print $1}')
./scripts/render-cask.sh 0.3.0 "$SHA" /tmp/codans.rb
brew style /tmp/codans.rb            # optional: run Homebrew's rubocop
brew install --cask /tmp/codans.rb   # optional: test the install
```

## Recovery

- **`brew install` fails with `Cask 'codans' is unavailable`.** The tap is missing. Use `brew install --cask wanggang316/tap/codans`, or `brew tap wanggang316/tap` and then `brew install --cask codans`.
- **Workflow says "cask already at v… in tap — nothing to push".** The rendered cask is the same as the tap copy, usually because the job ran again after a successful push. No action.
- **Workflow says the tap already has a newer version.** The job does not move the cask to an older version. No action, unless the newer version is wrong.
- **`sha256 mismatch`.** The DMG on the release does not match its `.sha256` file: the asset is corrupt or was replaced. Delete the release, then re-run all jobs of the `release-merge.yml` run.
- **Tap push fails with 403.** `HOMEBREW_TAP_TOKEN` expired or has no write access to the tap contents. Create a new PAT and set the secret again (step 3).
- **Push rejected three times.** Other runs pushed to the tap at the same time. Run the job again.

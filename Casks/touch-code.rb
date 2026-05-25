# Homebrew cask for touch-code.
#
# This file is the source of truth for the published cask. On every stable
# GitHub Release (`v*` tag, non-prerelease), `.github/workflows/update-cask.yml`
# substitutes `version` + `sha256` via `scripts/render-cask.sh` and pushes the
# rendered cask to `wanggang316/homebrew-tap` so that
# `brew install --cask wanggang316/tap/touch-code` resolves to the latest DMG.
#
# Sparkle handles in-app updates after install; `auto_updates true` tells
# Homebrew not to flag the post-Sparkle on-disk version as drift.
cask "touch-code" do
  version "0.3.0"
  sha256 "0000000000000000000000000000000000000000000000000000000000000000"

  url "https://github.com/wanggang316/touch-code/releases/download/v#{version}/TouchCode-#{version}.dmg",
      verified: "github.com/wanggang316/touch-code/"
  name "Touch Code"
  desc "Terminal orchestrator for CLI-agent power users (Project → Worktree → Tab → Pane)"
  homepage "https://github.com/wanggang316/touch-code"

  livecheck do
    url :url
    strategy :github_latest
  end

  auto_updates true
  depends_on macos: ">= :sonoma"

  app "TouchCode.app"
  binary "#{appdir}/TouchCode.app/Contents/Resources/bin/tc"

  zap trash: [
    "~/Library/Application Support/TouchCode",
    "~/Library/Caches/com.gumpw.touch-agent-mac",
    "~/Library/HTTPStorages/com.gumpw.touch-agent-mac",
    "~/Library/Preferences/com.gumpw.touch-agent-mac.plist",
    "~/Library/Saved Application State/com.gumpw.touch-agent-mac.savedState",
  ]
end

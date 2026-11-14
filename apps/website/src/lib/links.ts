export const LINKS = {
  repo: "https://github.com/wanggang316/codans",
  author: "https://github.com/wanggang316",
  // Release-independent direct download. GitHub resolves
  // `releases/latest/download/<asset>` to the asset of that exact name in the
  // newest release. The page also resolves the current `.dmg` at runtime (see
  // Base.astro), so the download works when a release has no stable-named
  // asset.
  latestDmg: "https://github.com/wanggang316/codans/releases/latest/download/Codans.dmg",
  latestReleaseApi: "https://api.github.com/repos/wanggang316/codans/releases/latest",
  brew: "brew install --cask wanggang316/tap/codans",
} as const;

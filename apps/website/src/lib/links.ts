export const LINKS = {
  repo: "https://github.com/wanggang316/codans",
  releases: "https://github.com/wanggang316/codans/releases",
  // On-site changelog page. The raw CHANGELOG.md on GitHub stays available
  // under `changelogSource` for anyone who wants the plain markdown.
  changelog: "/changelog",
  changelogSource: "https://github.com/wanggang316/codans/blob/main/CHANGELOG.md",
  issues: "https://github.com/wanggang316/codans/issues",
  latestDmg: "https://github.com/wanggang316/codans/releases/latest",
  // Release-independent direct download. GitHub resolves `releases/latest/
  // download/<asset>` to the newest release's asset of that exact name, so
  // this URL never changes per release — provided the release publishes a
  // stable-named `Codans.dmg` alongside the versioned artifact. Until that
  // asset exists, `useLatestDmgUrl` resolves the current .dmg at runtime.
  latestDmgDirect: "https://github.com/wanggang316/codans/releases/latest/download/Codans.dmg",
} as const;

/// <reference types="vite/client" />

// Repo-root CHANGELOG.md, injected by the `codans-changelog` plugin in
// vite.config.ts so the site stays the single source of truth for releases.
declare module "virtual:changelog-raw" {
  const raw: string;
  export default raw;
}

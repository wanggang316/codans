import { useEffect, useState } from "react";
import { LINKS } from "./links";

/**
 * Resolves the direct-download URL of the latest macOS .dmg.
 *
 * The static value ({@link LINKS.latestDmgDirect}) is a release-independent URL
 * that GitHub redirects to the newest release's stable-named asset. Until a
 * release publishes that stable name, this hook fills the gap at runtime: it
 * asks the GitHub API for the latest release and picks its `.dmg` asset, so the
 * download points at the current build without pinning a version in the page.
 * On any failure it keeps the static URL, which becomes valid once the
 * stable-named asset ships.
 */
export function useLatestDmgUrl(): string {
  const [url, setUrl] = useState<string>(LINKS.latestDmgDirect);

  useEffect(() => {
    const controller = new AbortController();
    fetch("https://api.github.com/repos/wanggang316/codans/releases/latest", {
      headers: { Accept: "application/vnd.github+json" },
      signal: controller.signal,
    })
      .then((r) => (r.ok ? r.json() : Promise.reject(new Error(`HTTP ${r.status}`))))
      .then((data: { assets?: { name: string; browser_download_url: string }[] }) => {
        const dmg = data.assets?.find((a) => a.name.toLowerCase().endsWith(".dmg"));
        if (dmg) setUrl(dmg.browser_download_url);
      })
      .catch(() => {
        /* Keep the static fallback. */
      });
    return () => controller.abort();
  }, []);

  return url;
}

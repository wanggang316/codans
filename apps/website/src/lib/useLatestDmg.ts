import { useEffect, useState } from "react";
import { LINKS } from "./links";

/**
 * The static value ({@link LINKS.latestDmgDirect}) is a release-independent URL
 * that GitHub redirects to the newest release's stable-named asset. Until a
 * release publishes that stable name, we resolve the current release's `.dmg`
 * from the GitHub API at runtime so the download works today and tracks every
 * release afterwards.
 *
 * The lookup is memoised at module scope so the several components that link to
 * the download (header, hero, CTA) share a single request per page load rather
 * than each firing their own. On failure the cache is cleared so a later mount
 * can retry, and callers fall back to the static URL meanwhile.
 */
let pending: Promise<string> | null = null;

function resolveLatestDmgUrl(): Promise<string> {
  if (!pending) {
    pending = fetch("https://api.github.com/repos/wanggang316/codans/releases/latest", {
      headers: { Accept: "application/vnd.github+json" },
    })
      .then((r) => (r.ok ? r.json() : Promise.reject(new Error(`HTTP ${r.status}`))))
      .then((data: { assets?: { name: string; browser_download_url: string }[] }) => {
        const dmg = data.assets?.find((a) => a.name.toLowerCase().endsWith(".dmg"));
        return dmg ? dmg.browser_download_url : LINKS.latestDmgDirect;
      })
      .catch(() => {
        pending = null;
        return LINKS.latestDmgDirect;
      });
  }
  return pending;
}

export function useLatestDmgUrl(): string {
  const [url, setUrl] = useState<string>(LINKS.latestDmgDirect);

  useEffect(() => {
    let active = true;
    resolveLatestDmgUrl().then((resolved) => {
      if (active) setUrl(resolved);
    });
    return () => {
      active = false;
    };
  }, []);

  return url;
}

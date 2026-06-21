// Parser for the repo-root CHANGELOG.md (Keep a Changelog format). The raw
// markdown is the single source of truth — see the `virtual:changelog-raw`
// plugin in vite.config.ts. This turns it into structured releases the
// ChangelogPage renders. Kept pure (string in, data out) so it's trivial to
// reason about and unit-test.

export type ChangeKind =
  | "Added"
  | "Changed"
  | "Deprecated"
  | "Removed"
  | "Fixed"
  | "Security";

export interface ChangeGroup {
  kind: ChangeKind;
  /** Raw inline markdown per bullet — wrapped lines collapsed to one space. */
  items: string[];
}

export interface Release {
  /** e.g. "0.4.11". "Unreleased" sections with no items are dropped. */
  version: string;
  /** ISO date from the header (e.g. "2026-06-21"), or null if undated. */
  date: string | null;
  groups: ChangeGroup[];
}

export function parseChangelog(raw: string): Release[] {
  const releases: Release[] = [];
  let release: Release | null = null;
  let group: ChangeGroup | null = null;
  let item: string | null = null;

  const flushItem = () => {
    if (item !== null && group) group.items.push(item.trim());
    item = null;
  };
  const flushGroup = () => {
    flushItem();
    if (group && release && group.items.length) release.groups.push(group);
    group = null;
  };
  const flushRelease = () => {
    flushGroup();
    // Drop empty sections (e.g. the [Unreleased] placeholder).
    if (release && release.groups.length) releases.push(release);
    release = null;
  };

  for (const line of raw.split("\n")) {
    // "## [0.4.11] - 2026-06-21" or "## [Unreleased]"
    const head = line.match(/^##\s+\[([^\]]+)\](?:\s*-\s*(.+?))?\s*$/);
    if (head) {
      flushRelease();
      release = { version: head[1].trim(), date: head[2]?.trim() ?? null, groups: [] };
      continue;
    }
    if (!release) continue; // skip the file preamble before the first release

    // "### Added"
    const kind = line.match(/^###\s+(.+?)\s*$/);
    if (kind) {
      flushGroup();
      group = { kind: kind[1].trim() as ChangeKind, items: [] };
      continue;
    }
    if (!group) continue;

    // "- item text" starts a bullet; indented lines continue the previous one.
    const bullet = line.match(/^-\s+(.*)$/);
    if (bullet) {
      flushItem();
      item = bullet[1];
    } else if (item !== null) {
      const cont = line.trim();
      if (cont) item += " " + cont;
    }
  }
  flushRelease();
  return releases;
}

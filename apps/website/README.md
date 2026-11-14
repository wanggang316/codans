# codans website

The [codans.dev](https://codans.dev) site: the home page and the changelog, in
English and Chinese.

## Stack

- Astro 7, static output, no client framework
- Tailwind CSS 4 (tokens and component classes in `src/styles/global.css`)
- System fonts; the page follows the system light or dark appearance

## Develop

Requires Node.js 22.23.4 or later.

```bash
pnpm install
pnpm dev          # http://localhost:4321
pnpm typecheck    # astro check
pnpm build        # output → dist/
pnpm preview      # serve the production build on http://localhost:4173
```

## Layout

```
src/
├── pages/                    # routes; each file only selects a view and a locale
│   ├── index.astro           #   /
│   ├── changelog.astro       #   /changelog
│   └── zh/                   #   /zh, /zh/changelog
├── views/                    # Home.astro, Changelog.astro
├── layouts/Base.astro        # <head>, nav, footer, download-link resolver
├── components/               # Nav, Footer, Download, BrewCommand, Shot
├── i18n/                     # en.ts defines the dictionary shape; zh.ts must match it
├── lib/
│   ├── changelog.ts          # parse CHANGELOG.md → structured releases
│   ├── inline-markdown.ts    # changelog bullet → safe inline HTML
│   ├── links.ts              # external URLs
│   └── shots.ts              # media and size of a product shot
└── styles/global.css
public/shots/                 # product screenshots and recordings
scripts/build-shots.py        # raw captures → public/shots + src/data/shots.json
```

`build.format` is `file`, so the build emits `changelog.html` and GitHub Pages
serves the clean `/changelog` URL. The changelog page reads the repository-root
`CHANGELOG.md` at build time.

To add a string, add it to `src/i18n/en.ts` and `src/i18n/zh.ts`. The type
checker reports a key that is missing from `zh.ts`.

## Product shots

The home page shows real captures of the app. Each shot has an id, and the
`Shot` component reads these files:

| File | Purpose |
|---|---|
| `public/shots/<id>.webp` | Still image. Also the poster of a recording. |
| `public/shots/<id>.mp4` | Optional. A silent screen recording that plays in place of the still. |
| `src/data/shots.json` | Pixel size of each still, and the ids that have a recording. |

A card with more than one shot id shows them as frames (`Frames` component):
the first frame is the still, and the others play while the pointer is over the
card. A click stops the play and shows the next frame; the frames play again
the next time the pointer enters the card. A recording plays in the same way. On a device without hover, both play
while they are on screen.

`scripts/build-shots.py <captures dir> public/shots src/data/shots.json` makes
all three from the raw captures: it crops, scales, encodes WebP, and writes the
manifest. The job list at the top of the script names each raw capture and its
crop box. It needs Python 3 with Pillow. The raw captures are not in the
repository.

| Ids | What they show |
|---|---|
| `hero-palette`, `hero-start`, `hero-build`, `hero-review`, `hero-team`, `hero-pr` | The tour scenes: the full window, one tab, in front of a backdrop. Command palette; New Agent dialog; agent beside a dev server (7:3); agent beside a live diff (4:6); five agents without the sidebar; the pull request popover. Themes: GitHub Dark Default, GitHub Light Default, Gruvbox Dark, Rosé Pine Dawn. |
| `agents-view-1..3`, `new-agent`, `queue-1..2`, `sessions-1..3`, `profile`, `handoff`, `notifications-1..2`, `persistence`, `cli-1..2` | The Agent-first cards: one cropped detail for each feature. Ids with a number are the frames of one flow. |
| `sidebar`, `panes-team` (recording), `layout` | The Parallel section. |
| `pr-popover`, `mr-popover`, `diff` | The Pull requests section: GitHub, GitLab, and the diff window. |
| `filter-*`, `theme-*`, `palette`, `run-menu`, `shortcuts`, `open-in` | The last section. |
| `og.png` | Link preview image. |

Capture rules:

- Use a demo data set with realistic repositories and real agent sessions. Do
  not show private project content, paths outside the demo directory, or prompts.
- Capture the window at 2x with `screencapture -l <window id>`. Popovers, menus,
  and sheets are separate windows: capture the screen region and paste it onto
  the window capture.
- A tour scene is a screen region, not a window capture: the sidebar and the
  header are glass, and they show the backdrop only when it is on screen. Put a
  borderless window with the backdrop image behind the app window, make the app
  active, and capture the region with `screencapture -R`.
- Backdrops must be free to use: public-domain photos (NASA, US National Park
  Service, Bureau of Land Management), generated images, or plain colors. Do not
  use the wallpapers that come with macOS.
- Make the app window key and give one pane the focus before each capture.
  Panes without focus are dimmed.
- Start each terminal program in the theme of the capture. Some programs read
  the background color only when they start.
- Show more than one agent state in the Agents View: working, waiting for
  approval, done, and idle.
- A tour scene is a 1920 x 1048 point region with the 1440 x 900 window in the
  center. `build-shots.py` crops it to 1664 x 1044; `global.css` uses the same
  numbers to make the window as wide as the text column.
- Use one tab in each worktree.
- Keep recordings under 15 seconds and under 2 MB. They loop without sound.
- The numbers in the Parallel section are measurements. Measure again before you
  change them, and keep the conditions in the note below them.

## Deploy

`.github/workflows/website.yml` builds the site and publishes `dist/` to GitHub
Pages on each push to `main` that changes `apps/website/**` or `CHANGELOG.md`.

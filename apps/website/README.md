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
│   └── shots.ts              # find the media files of a product shot
└── styles/global.css
public/shots/                 # product screenshots and recordings
```

`build.format` is `file`, so the build emits `changelog.html` and GitHub Pages
serves the clean `/changelog` URL. The changelog page reads the repository-root
`CHANGELOG.md` at build time.

To add a string, add it to `src/i18n/en.ts` and `src/i18n/zh.ts`. The type
checker reports a key that is missing from `zh.ts`.

## Product shots

The home page shows real captures of the app. Each shot has an id, and the
`Shot` component looks for these files in `public/shots/`:

| File | Purpose |
|---|---|
| `<id>.png` | Still image. Also the poster of a recording. |
| `<id>-dark.png` | Optional. Shown when the system appearance is dark. |
| `<id>.mp4` | Optional. A silent screen recording that plays in place of the still. |

A shot without a PNG file renders as a labelled empty frame.

| Id | What to capture |
|---|---|
| `hero` | The full window. Sidebar with three projects and several worktrees, Agents View with agents in the working, blocked, and done states, and a terminal pane with an agent at work. |
| `new-agent` | The New Agent dialog (⌘⇧N) with a project, a new worktree name, an agent, and a prompt filled in. |
| `agents-view` | The Agents View with at least one agent in each state, and a notification for a blocked agent. |
| `handoff` | One tab with two panes side by side: the source agent after `codans handoff`, and the receiver that starts on the briefing. |
| `review` | The diff window with a few changed files, and the pull request popover of a worktree with checks and the merge button. |

Capture rules:

- Use a demo data set. Do not show private project names, paths, or prompts.
- Capture at 2x and crop to the window.
- Keep recordings under 15 seconds and under 2 MB. They loop without sound.

## Deploy

`.github/workflows/website.yml` builds the site and publishes `dist/` to GitHub
Pages on each push to `main` that changes `apps/website/**` or `CHANGELOG.md`.

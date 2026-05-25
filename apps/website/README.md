# touch-code website

Marketing landing page for [touch-code](https://github.com/wanggang316/touch-code).

## Stack

- Vite 6 + React 18 + TypeScript
- Tailwind CSS 3
- framer-motion (all animations)
- react-i18next (English first, structure ready for additional locales under `src/locales/`)

## Develop

```bash
pnpm install
pnpm dev          # http://localhost:5173
pnpm build        # output → dist/
pnpm preview      # serve the production build locally
```

## Layout

```
src/
├── App.tsx
├── main.tsx
├── i18n.ts
├── locales/en/landing.json     # all visible strings live here
├── styles/globals.css
├── lib/
│   ├── links.ts                # external URLs
│   └── useTypewriter.ts        # canned-output typing hook
├── components/                 # shared chrome: Nav, Footer, Logo, Button, SectionHeader,
│                               # TerminalWindow, Pane, AppWindow
└── sections/                   # the page itself:
    ├── Hero.tsx                # animated 4-pane app window + tagline
    ├── AgentMatrix.tsx         # 16-pane parallel-agent grid (Section ①)
    ├── Hierarchy.tsx           # Project → Worktree → Tab → Pane SVG (§2)
    ├── Worktree.tsx            # animated git graph (§3)
    ├── CliSection.tsx          # tc CLI showcase (§4)
    ├── Native.tsx              # libghostty / Swift 6 / Apple Silicon (§5)
    └── CtaStrip.tsx
```

## Adding a locale

1. Create `src/locales/<code>/landing.json` mirroring `en/landing.json`.
2. Register it in `src/i18n.ts` and switch `lng`.

Every visible string already routes through `t('...')` — no component changes needed.

## Assets

`public/logo.png` is the production-rendered touch-code icon, sourced from
`apps/mac/touch-code/App/AppIcon.icon/Assets/2.png` and resized to 512×512.
Regenerate via:

```bash
python3 -c "from PIL import Image; \
  Image.open('../mac/touch-code/App/AppIcon.icon/Assets/2.png').resize((512,512)).save('public/logo.png', optimize=True)"
```

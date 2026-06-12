# codans website

Marketing landing page for [Codans](https://github.com/wanggang316/codans).

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
├── locales/<en|zh>/landing.json  # all visible strings live here
├── styles/globals.css
├── lib/
│   ├── links.ts                # external URLs
│   └── useTypewriter.ts        # canned-output typing hook
├── components/                 # shared chrome: Nav, Footer, Logo
└── sections/                   # the page itself:
    ├── Hero.tsx                # app screenshot + tagline
    ├── Features.tsx            # "What is Codans?" intro + feature list
    └── CtaStrip.tsx
```

## Adding a locale

1. Create `src/locales/<code>/landing.json` mirroring `en/landing.json`.
2. Register it in `src/i18n.ts` and switch `lng`.

Every visible string already routes through `t('...')` — no component changes needed.

## Assets

`public/logo.png` is the production-rendered Codans icon, sourced from
`apps/mac/codans/App/AppIcon.icon/Assets/logo1024-dark.png` (the active layer
of the app's `.icon` bundle). Regenerate all three derived sizes via:

```bash
python3 -c "
from PIL import Image
src = Image.open('../mac/codans/App/AppIcon.icon/Assets/logo1024-dark.png').convert('RGB')
src.resize((512, 512), Image.LANCZOS).save('public/logo.png', optimize=True)
src.resize((96, 96), Image.LANCZOS).save('public/favicon.png', optimize=True)
src.resize((256, 256), Image.LANCZOS).save('src/assets/logo-256.png', optimize=True)"
```

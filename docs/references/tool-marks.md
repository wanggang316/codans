# Tool marks

The `tool-*.imageset` assets in `apps/mac/codans/App/Assets.xcassets` are the
monochrome marks behind `ToolMark` (`apps/mac/CodansCore/Settings/CommandIcon/`).
They are shared by command icons (Settings → Commands, the `+` menu's detected
commands, the header Run button, Command Palette, tab chips) and the worktree
foreground-process list.

All marks except `tool-mise` use unmodified SVG artwork from
[Simple Icons](https://github.com/simple-icons/simple-icons) **16.32.0**
(fetched from `cdn.jsdelivr.net/npm/simple-icons@16.32.0/icons/`). Simple Icons
distributes these assets under
[CC0 1.0 Universal](https://github.com/simple-icons/simple-icons/blob/develop/LICENSE.md).
Brand names and trademarks remain with their respective owners; the marks are
used only to identify the tool a command runs.

`tool-mise` is original artwork (a bowl with three ingredients — *mise en
place*), drawn on the same 24-by-24 view box as a single filled path, because
mise has no monochrome mark upstream. Playwright has no Simple Icons entry; the
mapping uses the SF Symbol `theatermasks.fill`, which matches its logo.

| Asset | Source |
| --- | --- |
| `tool-nodejs` | `icons/nodedotjs.svg` |
| `tool-npm` | `icons/npm.svg` |
| `tool-pnpm` | `icons/pnpm.svg` |
| `tool-yarn` | `icons/yarn.svg` |
| `tool-bun` | `icons/bun.svg` |
| `tool-deno` | `icons/deno.svg` |
| `tool-vite` | `icons/vite.svg` |
| `tool-vitest` | `icons/vitest.svg` |
| `tool-jest` | `icons/jest.svg` |
| `tool-eslint` | `icons/eslint.svg` |
| `tool-prettier` | `icons/prettier.svg` |
| `tool-biome` | `icons/biome.svg` |
| `tool-typescript` | `icons/typescript.svg` |
| `tool-webpack` | `icons/webpack.svg` |
| `tool-esbuild` | `icons/esbuild.svg` |
| `tool-storybook` | `icons/storybook.svg` |
| `tool-cypress` | `icons/cypress.svg` |
| `tool-turborepo` | `icons/turborepo.svg` |
| `tool-nx` | `icons/nx.svg` |
| `tool-nextjs` | `icons/nextdotjs.svg` |
| `tool-nuxt` | `icons/nuxt.svg` |
| `tool-astro` | `icons/astro.svg` |
| `tool-svelte` | `icons/svelte.svg` |
| `tool-angular` | `icons/angular.svg` |
| `tool-expo` | `icons/expo.svg` |
| `tool-electron` | `icons/electron.svg` |
| `tool-tauri` | `icons/tauri.svg` |
| `tool-flutter` | `icons/flutter.svg` |
| `tool-dart` | `icons/dart.svg` |
| `tool-python` | `icons/python.svg` |
| `tool-uv` | `icons/uv.svg` |
| `tool-poetry` | `icons/poetry.svg` |
| `tool-pytest` | `icons/pytest.svg` |
| `tool-django` | `icons/django.svg` |
| `tool-flask` | `icons/flask.svg` |
| `tool-ruby` | `icons/ruby.svg` |
| `tool-rails` | `icons/rubyonrails.svg` |
| `tool-php` | `icons/php.svg` |
| `tool-swift` | `icons/swift.svg` |
| `tool-kotlin` | `icons/kotlin.svg` |
| `tool-gradle` | `icons/gradle.svg` |
| `tool-go` | `icons/go.svg` |
| `tool-rust` | `icons/rust.svg` |
| `tool-elixir` | `icons/elixir.svg` |
| `tool-make` | `icons/make.svg` |
| `tool-cmake` | `icons/cmake.svg` |
| `tool-just` | `icons/just.svg` |
| `tool-task` | `icons/task.svg` |
| `tool-mise` | drawn in-house (no upstream monochrome mark) |
| `tool-docker` | `icons/docker.svg` |
| `tool-kubernetes` | `icons/kubernetes.svg` |
| `tool-terraform` | `icons/terraform.svg` |
| `tool-ansible` | `icons/ansible.svg` |
| `tool-prisma` | `icons/prisma.svg` |
| `tool-git` | `icons/git.svg` |
| `tool-github` | `icons/github.svg` |

The image sets preserve vector representation and use template rendering so
the app supplies the foreground color (the command's tint, or secondary text in
the process list) in either appearance. Views size them to the SF Symbol they
sit beside; the source artwork keeps its 24-by-24 view box.

## Adding a mark

1. Add a `ToolMark` case (its raw value is persisted as `mark:<raw>` — never
   rename a shipped case) and map its executable names in
   `CommandIconCatalog.toolIcons`.
2. Add `tool-<raw>.imageset` with the upstream SVG and the same `Contents.json`
   properties (template rendering, preserved vector). Prefer Simple Icons; draw
   a mark only when neither Simple Icons nor SF Symbols has a fitting glyph,
   keeping to one filled path on the 24-by-24 grid.
3. Check it at 11–14 pt in light and dark before shipping — marks that are
   illustrations or thin wordmarks (Composer, GNU, Maven, .NET) were left out
   because they read as noise at menu size.
4. Record the source in the table above.

import Foundation

/// A developer tool's bundled monochrome mark — for tools SF Symbols has no
/// glyph for (npm, vite, docker, …). Raw values are persisted inside icon
/// strings (`mark:<rawValue>`, see `CommandIconRef`), so a case is never
/// renamed once shipped; add a new case instead.
///
/// Marks are template images (24×24 viewBox, single colour) and take the
/// surrounding tint like an SF Symbol does. Nearly all come from Simple Icons
/// (CC0); `mise` is drawn in-house because the project has no monochrome mark.
public nonisolated enum ToolMark: String, CaseIterable, Sendable, Hashable {
  // JavaScript runtimes and package managers
  case nodejs, npm, pnpm, yarn, bun, deno
  // Web build, test and quality tooling
  case vite, vitest, jest, eslint, prettier, biome, typescript, webpack, esbuild
  case storybook, cypress, turborepo, nx
  // App frameworks
  case nextjs, nuxt, astro, svelte, angular, expo, electron, tauri, flutter, dart
  // Other languages and their tooling
  case python, uv, poetry, pytest, django, flask
  case ruby, rails, php, swift, kotlin, gradle, go, rust, elixir
  // Build runners
  case make, cmake, just, task, mise
  // Infrastructure and source control
  case docker, kubernetes, terraform, ansible, prisma, git, github

  /// Human-readable tool name for pickers and accessibility.
  public var displayName: String {
    switch self {
    case .nodejs: return "Node.js"
    case .npm: return "npm"
    case .pnpm: return "pnpm"
    case .yarn: return "Yarn"
    case .bun: return "Bun"
    case .deno: return "Deno"
    case .vite: return "Vite"
    case .vitest: return "Vitest"
    case .jest: return "Jest"
    case .eslint: return "ESLint"
    case .prettier: return "Prettier"
    case .biome: return "Biome"
    case .typescript: return "TypeScript"
    case .webpack: return "webpack"
    case .esbuild: return "esbuild"
    case .storybook: return "Storybook"
    case .cypress: return "Cypress"
    case .turborepo: return "Turborepo"
    case .nx: return "Nx"
    case .nextjs: return "Next.js"
    case .nuxt: return "Nuxt"
    case .astro: return "Astro"
    case .svelte: return "Svelte"
    case .angular: return "Angular"
    case .expo: return "Expo"
    case .electron: return "Electron"
    case .tauri: return "Tauri"
    case .flutter: return "Flutter"
    case .dart: return "Dart"
    case .python: return "Python"
    case .uv: return "uv"
    case .poetry: return "Poetry"
    case .pytest: return "pytest"
    case .django: return "Django"
    case .flask: return "Flask"
    case .ruby: return "Ruby"
    case .rails: return "Rails"
    case .php: return "PHP"
    case .swift: return "Swift"
    case .kotlin: return "Kotlin"
    case .gradle: return "Gradle"
    case .go: return "Go"
    case .rust: return "Rust"
    case .elixir: return "Elixir"
    case .make: return "Make"
    case .cmake: return "CMake"
    case .just: return "just"
    case .task: return "Task"
    case .mise: return "mise"
    case .docker: return "Docker"
    case .kubernetes: return "Kubernetes"
    case .terraform: return "Terraform"
    case .ansible: return "Ansible"
    case .prisma: return "Prisma"
    case .git: return "Git"
    case .github: return "GitHub"
    }
  }
}

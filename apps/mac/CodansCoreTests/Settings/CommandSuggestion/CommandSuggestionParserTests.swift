import Foundation
import Testing

@testable import CodansCore

struct PackageJSONParserTests {
  private let parser = PackageJSONParser()

  private func snapshot(_ json: String, present: Set<String> = []) -> ManifestSnapshot {
    ManifestSnapshot(contents: ["package.json": json], presentPaths: present)
  }

  @Test
  func listsScriptsSortedWithBodiesAsDetail() {
    let result = parser.suggestions(
      in: snapshot(#"{ "scripts": { "dev": "vite", "build": "vite build" } }"#))
    #expect(result.map(\.name) == ["build", "dev"])
    #expect(result.map(\.command) == ["npm run build", "npm run dev"])
    #expect(result.map(\.detail) == ["vite build", "vite"])
    #expect(result.map(\.kind) == [.custom, .run])
  }

  @Test
  func declaredPackageManagerWinsOverLockfile() {
    let result = parser.suggestions(
      in: snapshot(
        #"{ "packageManager": "pnpm@9.1.0+sha512.abc", "scripts": { "dev": "vite" } }"#,
        present: ["yarn.lock"]))
    #expect(result.first?.command == "pnpm run dev")
  }

  @Test
  func lockfilePicksManager() {
    for (lockfile, manager) in [
      ("pnpm-lock.yaml", "pnpm"), ("yarn.lock", "yarn"), ("bun.lockb", "bun"), ("package-lock.json", "npm"),
    ] {
      let result = parser.suggestions(
        in: snapshot(#"{ "scripts": { "test": "vitest" } }"#, present: [lockfile]))
      #expect(result.first?.command == "\(manager) run test", "lockfile \(lockfile)")
    }
  }

  @Test
  func unknownDeclaredManagerFallsBackToLockfile() {
    let result = parser.suggestions(
      in: snapshot(#"{ "packageManager": "deno@2", "scripts": { "a": "x" } }"#, present: ["yarn.lock"]))
    #expect(result.first?.command == "yarn run a")
  }

  @Test
  func dropsLifecycleHooksOnlyWhenBaseExists() {
    let result = parser.suggestions(
      in: snapshot(
        #"{ "scripts": { "build": "tsc", "prebuild": "rm -rf dist", "postinstall": "patch", "preview": "vite preview" } }"#
      ))
    // `postinstall` has no `install` script, `preview` has no `view`: both stay.
    #expect(result.map(\.name) == ["build", "postinstall", "preview"])
  }

  @Test
  func quotesUnsafeScriptNames() {
    let result = parser.suggestions(in: snapshot(#"{ "scripts": { "test:unit": "x", "a b": "y" } }"#))
    #expect(result.map(\.command) == ["npm run 'a b'", "npm run test:unit"])
  }

  @Test
  func malformedOrMissingManifestYieldsNothing() {
    #expect(parser.suggestions(in: snapshot("{ not json")).isEmpty)
    #expect(parser.suggestions(in: snapshot(#"{ "name": "x" }"#)).isEmpty)
    #expect(parser.suggestions(in: ManifestSnapshot()).isEmpty)
  }
}

struct JSONScriptTableParserTests {
  @Test
  func denoTasksAcceptStringAndObjectEntries() {
    let snapshot = ManifestSnapshot(contents: [
      "deno.json": #"{ "tasks": { "dev": "deno run -A main.ts", "check": { "command": "deno check" } } }"#
    ])
    let result = DenoTaskParser().suggestions(in: snapshot)
    #expect(result.map(\.command) == ["deno task check", "deno task dev"])
    #expect(result.map(\.detail) == ["deno check", "deno run -A main.ts"])
  }

  @Test
  func composerScriptsJoinStepLists() {
    let snapshot = ManifestSnapshot(contents: [
      "composer.json": #"{ "scripts": { "test": ["phpunit", "phpstan"] } }"#
    ])
    let result = ComposerScriptParser().suggestions(in: snapshot)
    #expect(result.first?.command == "composer run-script test")
    #expect(result.first?.detail == "phpunit && phpstan")
  }
}

struct MakefileParserTests {
  private func suggest(_ text: String, file: String = "Makefile") -> [CommandSuggestion] {
    MakefileParser().suggestions(in: ManifestSnapshot(contents: [file: text]))
  }

  @Test
  func phonyTargetsLeadAndHelpCommentsBecomeDetail() {
    let result = suggest(
      """
      CC := clang
      VERSION ?= 1.0
      .PHONY: build test
      .DEFAULT_GOAL := build

      out/app: main.c
      \t$(CC) -o $@ $<

      build: out/app ## Build the app
      \t@echo done

      test: build
      \t./run-tests
      %.o: %.c
      \t$(CC) -c $<
      _internal:
      \ttrue
      """)
    #expect(result.map(\.name) == ["build", "test"])
    #expect(result.first?.command == "make build")
    #expect(result.first?.detail == "Build the app")
  }

  @Test
  func nonPhonyLiteralTargetsFollowPhonyOnes() {
    let result = suggest(
      """
      docs:
      \tmkdocs build
      .PHONY: lint
      lint:
      \truff .
      clean install: ; rm -rf build
      """)
    #expect(result.map(\.name) == ["lint", "docs", "clean", "install"])
  }

  @Test
  func assignmentsAndTargetVariablesAreNotRules() {
    let result = suggest(
      """
      export PATH := bin:$(PATH)
      URL = http://example.com
      debug: CFLAGS = -g
      debug:
      \tmake all
      """)
    #expect(result.map(\.name) == ["debug"])
  }

  @Test
  func gnuMakefileTakesPrecedence() {
    let snapshot = ManifestSnapshot(contents: ["GNUmakefile": "gnu:\n", "Makefile": "plain:\n"])
    #expect(MakefileParser().suggestions(in: snapshot).map(\.name) == ["gnu"])
  }
}

struct JustfileParserTests {
  @Test
  func listsPublicRecipesWithDocComments() {
    let text = """
      set shell := ["bash", "-c"]
      alias b := build
      version := "1.0"

      # Build everything
      build target="debug": deps
          cargo build

      @deps:
          echo deps

      _helper:
          true

      # Hidden despite the comment
      [private]
      secret:
          true

      [group('ci')]
      test-all *args:
          cargo test {{args}}
      """
    let result = JustfileParser().suggestions(in: ManifestSnapshot(contents: ["justfile": text]))
    #expect(result.map(\.name) == ["build", "deps", "test-all"])
    #expect(result.map(\.command) == ["just build", "just deps", "just test-all"])
    #expect(result.first?.detail == "Build everything")
    #expect(result[1].detail == nil)
  }
}

struct TaskfileParserTests {
  @Test
  func listsTopLevelTasksSkippingInternalOnes() {
    let text = """
      version: '3'
      vars:
        NAME: app
      tasks:
        build:
          desc: "Build the binary"
          cmds:
            - go build ./...
        'lint:fix':
          cmds: [golangci-lint run --fix]
        setup:
          internal: true
          cmds:
            - echo hi
      includes:
        docs: ./docs
      """
    let result = TaskfileParser().suggestions(in: ManifestSnapshot(contents: ["Taskfile.yml": text]))
    #expect(result.map(\.name) == ["build", "lint:fix"])
    #expect(result.map(\.command) == ["task build", "task lint:fix"])
    #expect(result.first?.detail == "Build the binary")
    #expect(result.map(\.kind) == [.custom, .lint])
  }
}

struct MiseTaskParserTests {
  @Test
  func readsTableAndInlineTaskForms() {
    let text = """
      [tools]
      node = "22"

      [tasks]
      fmt = "prettier -w ."
      lint = { run = "eslint .", description = "Lint sources" }

      [tasks.build]
      description = "Build the app"
      run = "vite build"

      [tasks."test:e2e"]
      run = ["playwright test"]

      [tasks.build.env]
      NODE_ENV = "production"
      """
    let result = MiseTaskParser().suggestions(in: ManifestSnapshot(contents: ["mise.toml": text]))
    #expect(result.map(\.name) == ["fmt", "lint", "build", "test:e2e"])
    #expect(result.map(\.command) == ["mise run fmt", "mise run lint", "mise run build", "mise run test:e2e"])
    #expect(result.map(\.detail) == ["prettier -w .", "Lint sources", "Build the app", nil])
  }
}

struct ToolchainParserTests {
  @Test
  func presenceAloneOffersStandardVerbs() {
    let snapshot = ManifestSnapshot(presentPaths: ["Cargo.toml", "go.mod"])
    #expect(CargoParser().suggestions(in: snapshot).map(\.command).contains("cargo test"))
    #expect(GoModuleParser().suggestions(in: snapshot).map(\.command).contains("go test ./..."))
    #expect(SwiftPackageParser().suggestions(in: snapshot).isEmpty)
  }
}

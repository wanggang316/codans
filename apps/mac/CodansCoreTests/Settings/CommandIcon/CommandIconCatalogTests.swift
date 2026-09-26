import Foundation
import Testing

@testable import CodansCore

struct CommandIconCatalogTests {
  private func icon(_ name: String, _ command: String, body: String? = nil) -> CommandIconRef? {
    CommandIconCatalog.icon(forEntryName: name, command: command, body: body)
  }

  @Test
  func actionBeatsTheToolItRunsThrough() {
    #expect(icon("build", "pnpm run build", body: "vite build") == .symbol("hammer.fill"))
    #expect(icon("test:unit", "npm run test:unit", body: "vitest run") == .symbol("testtube.2"))
    #expect(icon("dev", "pnpm run dev", body: "next dev") == .symbol("play.fill"))
    #expect(icon("fmt", "cargo fmt") == .symbol("wand.and.stars"))
  }

  @Test
  func entryNamedAfterAToolUsesItsMark() {
    #expect(icon("storybook", "npm run storybook", body: "storybook dev -p 6006") == .mark(.storybook))
    #expect(icon("docker:build", "make docker:build") == .mark(.docker))
    #expect(icon("prisma", "npm run prisma") == .mark(.prisma))
  }

  @Test
  func unknownActionFallsBackToBodyThenRunner() {
    #expect(icon("gen:client", "npm run gen:client", body: "prisma generate") == .symbol("gearshape.2.fill"))
    #expect(icon("orm", "npm run orm", body: "NODE_ENV=dev cross-env prisma migrate") == .mark(.prisma))
    #expect(icon("stories", "npm run stories", body: "./node_modules/.bin/storybook dev") == .mark(.storybook))
    #expect(icon("e", "pnpm run e") == .mark(.pnpm))
    #expect(icon("whatever", "just whatever") == .mark(.just))
    #expect(icon("vet", "go vet ./...") == .symbol("checklist"))
    #expect(icon("zzz", "some-unknown-tool") == nil)
  }

  @Test
  func runnerIconLooksPastANestedCd() {
    #expect(CommandIconCatalog.runnerIcon(forCommand: "cd docker && pnpm run up") == .mark(.pnpm))
    #expect(CommandIconCatalog.runnerIcon(forCommand: "make build") == .mark(.make))
    #expect(CommandIconCatalog.runnerIcon(forCommand: "cd x && ./run.sh") == nil)
  }

  @Test
  func playwrightMapsToTheatreMasksSymbol() {
    #expect(icon("pw", "npm run pw", body: "playwright test --ui") == .symbol("theatermasks.fill"))
  }

  @Test
  func executablesResolveForTheProcessList() {
    #expect(CommandIconCatalog.toolIcon(forExecutable: "node") == .mark(.nodejs))
    #expect(CommandIconCatalog.toolIcon(forExecutable: "/opt/homebrew/bin/cargo") == .mark(.rust))
    #expect(CommandIconCatalog.toolIcon(forExecutable: "python3.12") == .mark(.python))
    #expect(CommandIconCatalog.toolIcon(forExecutable: "NPX") == .mark(.npm))
    #expect(CommandIconCatalog.toolIcon(forExecutable: "zsh") == nil)
  }

  @Test
  func everyMarkIsReachableFromTheTable() {
    let mapped = Set(CommandIconCatalog.toolIcons.values.compactMap { ref -> ToolMark? in
      if case .mark(let mark) = ref { return mark }
      return nil
    })
    #expect(mapped == Set(ToolMark.allCases))
  }
}

struct CommandIconRefTests {
  @Test
  func roundTripsSymbolsAndMarks() {
    for ref in [CommandIconRef.symbol("hammer.fill"), .mark(.npm), .mark(.mise)] {
      #expect(CommandIconRef(storedValue: ref.storedValue) == ref)
    }
    #expect(CommandIconRef.mark(.vite).storedValue == "mark:vite")
  }

  @Test
  func unknownMarkAndEmptyStringDoNotParse() {
    #expect(CommandIconRef(storedValue: "mark:from-the-future") == nil)
    #expect(CommandIconRef(storedValue: "  ") == nil)
  }

  @Test
  func scriptFallsBackToKindIconForUnknownMark() {
    let script = ScriptDefinition(kind: .test, systemImage: "mark:from-the-future")
    #expect(script.resolvedIcon == .symbol(ScriptKind.test.defaultSystemImage))
    #expect(script.resolvedSystemImage == ScriptKind.test.defaultSystemImage)
    let marked = ScriptDefinition(kind: .custom, systemImage: "mark:docker")
    #expect(marked.resolvedIcon == .mark(.docker))
    #expect(marked.resolvedSystemImage == "mark:docker")
  }
}

import Testing

@testable import Codans

@MainActor
struct DiffFileIconTests {
  /// The icon says what kind of file it is. It used to be whatever app claimed the extension, so
  /// `.java` wore the IntelliJ icon and `.tsx`, `.go` and `.cs` all wore the GoLand one.
  @Test func symbolsComeFromTheFileKindAndNotFromInstalledApps() {
    for path in ["src/Main.java", "app/App.tsx", "cmd/main.go", "src/Program.cs", "Cargo.toml", "a/b.py"] {
      #expect(DiffFileIcon.symbolName(for: path) == "curlybraces")
    }
    for path in ["README.md", "notes.txt", "Makefile", "Dockerfile", ".gitignore", "docs/index"] {
      #expect(DiffFileIcon.symbolName(for: path) == "doc.text")
    }
    #expect(DiffFileIcon.symbolName(for: "art/logo.png") == "photo")
    #expect(DiffFileIcon.symbolName(for: "dist/bundle.zip") == "doc.zipper")
    #expect(DiffFileIcon.symbolName(for: "docs/manual.pdf") == "doc.richtext")
  }

  @Test func everySymbolItNamesExists() {
    for path in ["a.java", "a.md", "a.png", "a.zip", "a.pdf", "a.mp4", "a.mp3", "a", "a.sqlite"] {
      #expect(DiffFileIcon.image(for: path) != nil, "no image for \(path)")
    }
  }
}

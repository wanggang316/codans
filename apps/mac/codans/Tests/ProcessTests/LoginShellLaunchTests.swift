import Foundation
import Testing

@testable import Codans

struct LoginShellLaunchTests {
  private let git = URL(fileURLWithPath: "/usr/bin/git")
  private let repo = URL(fileURLWithPath: "/tmp/my repo", isDirectory: true)

  @Test
  func shellFromLoginShellPath() {
    #expect(LoginShell(path: "/bin/zsh") == .zsh(URL(fileURLWithPath: "/bin/zsh")))
    #expect(LoginShell(path: "/opt/homebrew/bin/bash") == .bash(URL(fileURLWithPath: "/opt/homebrew/bin/bash")))
    #expect(LoginShell(path: "/opt/homebrew/bin/fish") == .fish(URL(fileURLWithPath: "/opt/homebrew/bin/fish")))
  }

  @Test(arguments: ["/bin/tcsh", "/usr/local/bin/nu", "/bin/sh", "zsh", "", nil] as [String?])
  func unsupportedShellFallsBackToZsh(path: String?) {
    #expect(LoginShell(path: path) == .zsh(URL(fileURLWithPath: "/bin/zsh")))
  }

  @Test
  func zshLaunchWithWorkingDirectory() throws {
    let launch = try LoginShellLaunch.build(
      executable: git,
      arguments: ["log", "--format=%an $x", "it's \"q\""],
      env: ["HOME": "/Users/u", "PATH": "/usr/bin:/bin", "LC_ALL": "C.UTF-8"],
      cwd: repo,
      shell: .zsh(URL(fileURLWithPath: "/bin/zsh"))
    )
    #expect(launch.executable.path == "/bin/sh")
    #expect(
      launch.arguments == [
        "-c", "exec 3>&1 4>&2 >/dev/null 2>&1; exec \"$0\" \"$@\"", "/bin/zsh",
        "-l", "-c",
        "__codans_dir=$1; shift; __codans_argv=(\"$@\"); set --; "
          + "if [ -r \"${ZDOTDIR:-$HOME}/.zshrc\" ]; then . \"${ZDOTDIR:-$HOME}/.zshrc\" </dev/null 3>&- 4>&-; fi; "
          + "builtin cd -- \"$__codans_dir\" || exit 125; "
          + "exec /usr/bin/env -i \"PATH=$PATH\" \"${__codans_argv[@]}\" 1>&3 2>&4 3>&- 4>&-",
        "--",
        "/tmp/my repo",
        "HOME=/Users/u", "LC_ALL=C.UTF-8",
        "/usr/bin/git", "log", "--format=%an $x", "it's \"q\"",
      ])
    // The shell starts with the caller's env; PATH reaches the command only
    // through the login shell.
    #expect(launch.environment == ["HOME": "/Users/u", "PATH": "/usr/bin:/bin", "LC_ALL": "C.UTF-8"])
    #expect(launch.currentDirectory.path == "/")
  }

  @Test
  func bashLaunchWithoutWorkingDirectory() throws {
    let launch = try LoginShellLaunch.build(
      executable: git, arguments: ["status", "a b"], env: ["HOME": "/h"], cwd: nil,
      shell: .bash(URL(fileURLWithPath: "/bin/bash"))
    )
    #expect(
      launch.arguments == [
        "-c", LoginShellLaunch.redirectScript, "/bin/bash",
        "-l", "-c",
        "__codans_argv=(\"$@\"); set --; "
          + "if [ -r \"$HOME/.bashrc\" ]; then . \"$HOME/.bashrc\" </dev/null 3>&- 4>&-; fi; "
          + "exec /usr/bin/env -i \"PATH=$PATH\" \"${__codans_argv[@]}\" 1>&3 2>&4 3>&- 4>&-",
        "--", "HOME=/h", "/usr/bin/git", "status", "a b",
      ])
  }

  @Test
  func fishLaunchWithAndWithoutWorkingDirectory() throws {
    let fish = LoginShell.fish(URL(fileURLWithPath: "/opt/homebrew/bin/fish"))
    let withDirectory = try LoginShellLaunch.build(
      executable: git, arguments: ["$x"], env: [:], cwd: repo, shell: fish)
    #expect(
      withDirectory.arguments == [
        "-c", LoginShellLaunch.redirectScript, "/opt/homebrew/bin/fish",
        "-l", "-c",
        "set -g __codans_dir $argv[1]; set -g __codans_argv $argv[2..-1]; set -e argv; "
          + "builtin cd $__codans_dir; or exit 125; "
          + "exec /usr/bin/env -i \"PATH=$PATH\" $__codans_argv 1>&3 2>&4 3>&- 4>&-",
        "--", "/tmp/my repo", "/usr/bin/git", "$x",
      ])
    let withoutDirectory = try LoginShellLaunch.build(
      executable: git, arguments: [], env: [:], cwd: nil, shell: fish)
    #expect(
      withoutDirectory.arguments == [
        "-c", LoginShellLaunch.redirectScript, "/opt/homebrew/bin/fish",
        "-l", "-c",
        "set -g __codans_argv $argv; set -e argv; "
          + "exec /usr/bin/env -i \"PATH=$PATH\" $__codans_argv 1>&3 2>&4 3>&- 4>&-",
        "--", "/usr/bin/git",
      ])
  }

  @Test
  func executablePathWithEqualsSignIsRejected() {
    #expect(throws: LoginShellLaunch.Failure.unsupportedExecutablePath("/a=b/git")) {
      try LoginShellLaunch.build(
        executable: URL(fileURLWithPath: "/a=b/git"), arguments: [], env: [:], cwd: nil, shell: .fallback)
    }
  }

  @Test
  func missingExecutableIsReportedBeforeLaunch() {
    #expect(throws: LoginShellLaunch.Failure.executableMissing("/nonexistent/glab")) {
      try LoginShellLaunch.prepare(
        executable: URL(fileURLWithPath: "/nonexistent/glab"), arguments: [], env: [:], cwd: nil)
    }
  }
}

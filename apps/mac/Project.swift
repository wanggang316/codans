import ProjectDescription

let ghosttyXCFrameworkPath: Path = ".build/ghostty/GhosttyKit.xcframework"
let ghosttyBuildScriptPath: Path = "scripts/build-ghostty.sh"

let ghosttyFingerprintInputScript = """
"${SRCROOT}/\(ghosttyBuildScriptPath.pathString)" --print-fingerprint
"""

let project = Project(
  name: "codans",
  settings: .settings(
    base: [
      // Debug uses Automatic signing for contributors without a
      // Developer ID. Release archives drive signing via xcodebuild
      // command-line build settings (see scripts/release.sh —
      // CODE_SIGN_STYLE=Manual etc. passed at invocation time), which
      // outrank anything set here.
      "CODE_SIGN_STYLE": "Automatic",
      "SWIFT_APPROACHABLE_CONCURRENCY": "YES",
      "SWIFT_DEFAULT_ACTOR_ISOLATION": "MainActor",
      "SWIFT_VERSION": "6.0",
    ],
    configurations: [
      .debug(name: .debug, xcconfig: "Configurations/Project.xcconfig"),
      .release(name: .release, xcconfig: "Configurations/Project.xcconfig"),
    ],
    defaultSettings: .essential
  ),
  targets: [
    // Shared domain types. Zero internal deps. Consumed by app + CLI.
    .target(
      name: "CodansCore",
      destinations: .macOS,
      product: .staticFramework,
      bundleId: "com.gumpw.codans.core",
      deploymentTargets: .macOS("14.0"),
      infoPlist: .default,
      buildableFolders: [
        "CodansCore",
        "CodansCore/Agents",
        "CodansCore/GitHub",
        "CodansCore/Notifications",
        "CodansCore/Shortcuts",
        "CodansCore/Shortcuts/ConflictDetectors",
        "CodansCore/StatusBar",
      ],
      settings: .settings(
        base: ["SWIFT_DEFAULT_ACTOR_ISOLATION": "nonisolated"],
        defaultSettings: .essential
      )
    ),

    // CodansCore unit tests. Links CodansIPC so IPC codable tests can
    // live here too (DEC-1: avoid proliferating test targets, per 0003 and
    // 0005 M1 DEC-5 — dedicated CodansIPCTests not justified).
    .target(
      name: "CodansCoreTests",
      destinations: .macOS,
      product: .unitTests,
      bundleId: "com.gumpw.codans.core-tests",
      deploymentTargets: .macOS("14.0"),
      infoPlist: .default,
      buildableFolders: [
        "CodansCoreTests",
        "CodansCoreTests/IPC",
        "CodansCoreTests/GitHubTests",
        "CodansCoreTests/Shortcuts",
      ],
      dependencies: [
        .target(name: "CodansCore"),
        .target(name: "CodansIPC"),
      ],
      settings: .settings(
        base: [
          "CODE_SIGNING_ALLOWED": "NO",
          "SWIFT_DEFAULT_ACTOR_ISOLATION": "nonisolated",
        ],
        defaultSettings: .essential
      )
    ),

    // JSON-RPC wire protocol. Consumed by app + CLI.
    .target(
      name: "CodansIPC",
      destinations: .macOS,
      product: .staticFramework,
      bundleId: "com.gumpw.codans.ipc",
      deploymentTargets: .macOS("14.0"),
      infoPlist: .default,
      buildableFolders: ["CodansIPC", "CodansIPC/WireTypes"],
      dependencies: [.target(name: "CodansCore")],
      settings: .settings(
        base: ["SWIFT_DEFAULT_ACTOR_ISOLATION": "nonisolated"],
        defaultSettings: .essential
      )
    ),

    // Ghostty foreign build. Produces GhosttyKit.xcframework from ThirdParty/ghostty.
    .foreignBuild(
      name: "GhosttyKit",
      destinations: .macOS,
      script: """
        "${SRCROOT}/\(ghosttyBuildScriptPath.pathString)"
        """,
      inputs: [
        .file("../../mise.toml"),
        .file(ghosttyBuildScriptPath),
        .script(ghosttyFingerprintInputScript),
      ],
      output: .xcframework(path: ghosttyXCFrameworkPath, linking: .static)
    ),

    // CodansKit: shared CLI library — Transport / RPCClient / Renderer /
    // ExitCode / SocketDiscovery. The codans binary is a thin wrapper;
    // parallel plans (C5 for skill command, future CLI extensions) link
    // into CodansKit rather than the codans binary.
    .target(
      name: "CodansKit",
      destinations: .macOS,
      product: .staticFramework,
      bundleId: "com.gumpw.codans.cli-kit",
      deploymentTargets: .macOS("14.0"),
      infoPlist: .default,
      buildableFolders: [
        "CodansKit",
        "CodansKit/Transport",
        "CodansKit/Render",
      ],
      dependencies: [
        .target(name: "CodansCore"),
        .target(name: "CodansIPC"),
        .external(name: "ArgumentParser"),
      ],
      settings: .settings(
        base: ["SWIFT_DEFAULT_ACTOR_ISOLATION": "nonisolated"],
        defaultSettings: .essential
      )
    ),

    // CodansKit unit tests. Headless — uses InMemoryTransport, does not
    // reach into the Codans app target.
    .target(
      name: "CodansKitTests",
      destinations: .macOS,
      product: .unitTests,
      bundleId: "com.gumpw.codans.cli-kit-tests",
      deploymentTargets: .macOS("14.0"),
      infoPlist: .default,
      buildableFolders: ["CodansKitTests"],
      dependencies: [
        .target(name: "CodansKit"),
        .target(name: "CodansCore"),
        .target(name: "CodansIPC"),
      ],
      settings: .settings(
        base: [
          "CODE_SIGNING_ALLOWED": "NO",
          "SWIFT_DEFAULT_ACTOR_ISOLATION": "nonisolated",
        ],
        defaultSettings: .essential
      )
    ),

    // codans CLI binary. Thin wrapper around CodansKit — Runtime / Hooks / Git
    // are intentionally off-limits per architecture dep rules. Isolation
    // default is `nonisolated` to match the ArgumentParser command
    // conventions (commands run off the main actor). Target is named
    // `codans-cli` to stay distinct from the `Codans` app target; the
    // emitted binary's PRODUCT_NAME is `codans`.
    .target(
      name: "codans-cli",
      destinations: .macOS,
      product: .commandLineTool,
      bundleId: "com.gumpw.codans.cli",
      deploymentTargets: .macOS("14.0"),
      infoPlist: .default,
      buildableFolders: ["codans-cli", "codans-cli/Commands"],
      dependencies: [
        .target(name: "CodansKit"),
        .target(name: "CodansCore"),
        .target(name: "CodansIPC"),
        .external(name: "ArgumentParser"),
      ],
      settings: .settings(
        base: [
          // Debug skips signing so contributors without a Developer ID
          // can build the CLI. Release archives override signing via
          // xcodebuild command-line build settings (release.sh) which
          // win over anything Tuist injects here. Hardened Runtime is
          // mandatory for notarization on the embedded codans — set it on
          // the target so it's part of the project, not the cmdline.
          "CODE_SIGNING_ALLOWED[config=Debug]": "NO",
          "ENABLE_HARDENED_RUNTIME[config=Release]": "YES",
          "PRODUCT_NAME": "codans",
          "SWIFT_DEFAULT_ACTOR_ISOLATION": "nonisolated",
        ],
        defaultSettings: .essential
      )
    ),

    // Mac app. Runtime / Hooks / Git are in-app modules (subfolders, not separate targets).
    // codans-cli is a dependency so app builds produce the CLI binary alongside the .app bundle.
    .target(
      name: "Codans",
      destinations: .macOS,
      product: .app,
      productName: "Codans",
      bundleId: "com.gumpw.codans",
      deploymentTargets: .macOS("14.0"),
      infoPlist: .file(path: "Configurations/mac-Info.plist"),
      buildableFolders: [
        "codans/App",
        "codans/App/Features/Socket",
        "codans/App/Features/Socket/handlers",
        "codans/App/Features/GitHub",
        "codans/App/Features/GitHub/Theme",
        "codans/App/Features/GitHub/Views",
        "codans/App/Features/MasterTerminal",
        "codans/App/Features/MasterTerminal/Resources",
        "codans/Runtime",
        "codans/Process",
        "codans/Git",
        "codans/GitHub",
      ],
      entitlements: .file(path: "Configurations/codans.entitlements"),
      // git-wt submodule wiring. Pre-script fails the build cleanly when
      // the submodule is not checked out; post-script copies only the `wt`
      // file into Resources/git-wt/wt so Bundle.main.url(forResource:
      // "wt", subdirectory: "git-wt") resolves at runtime.
      scripts: [
        .pre(
          script: "\"${SRCROOT}/scripts/verify-git-wt.sh\"",
          name: "Verify git-wt",
          basedOnDependencyAnalysis: false
        ),
        .post(
          script: "\"${SRCROOT}/scripts/embed-git-wt.sh\"",
          name: "Embed git-wt",
          inputPaths: [
            "$(SRCROOT)/ThirdParty/git-wt/wt",
          ],
          outputPaths: [
            "$(TARGET_BUILD_DIR)/$(UNLOCALIZED_RESOURCES_FOLDER_PATH)/git-wt/wt",
          ],
          basedOnDependencyAnalysis: false
        ),
        // codans CLI embedding. Copies the codans binary built by its sibling
        // target into Resources/bin/codans so the app can ship a single
        // self-contained .app and `codans skill install` / first-launch
        // installer (c4-cli D3) have a stable inside-bundle path to
        // symlink from ~/.local/bin/codans.
        .post(
          script: "\"${SRCROOT}/scripts/embed-codans.sh\"",
          name: "Embed codans",
          inputPaths: [
            "$(CONFIGURATION_BUILD_DIR)/codans",
          ],
          outputPaths: [
            "$(TARGET_BUILD_DIR)/$(UNLOCALIZED_RESOURCES_FOLDER_PATH)/bin/codans",
          ],
          basedOnDependencyAnalysis: true
        ),
        // zmx pane-resume daemon embedding. The zmx binary is built by
        // the Makefile's build-zmx prerequisite (out-of-band from Tuist,
        // since it's a vendored Zig build) and lives at
        // .build/zmx/bin/zmx. This script copies it alongside codans under
        // Resources/bin so the running app can spawn it from a stable
        // inside-bundle path. Must run after "Embed codans" because that
        // script wipes Resources/bin before copying codans.
        .post(
          script: "\"${SRCROOT}/scripts/embed-zmx.sh\"",
          name: "Embed zmx",
          inputPaths: [
            "$(SRCROOT)/.build/zmx/bin/zmx",
          ],
          outputPaths: [
            "$(TARGET_BUILD_DIR)/$(UNLOCALIZED_RESOURCES_FOLDER_PATH)/bin/zmx",
          ],
          basedOnDependencyAnalysis: true
        ),
        // Ghostty resources: themes (~480 files), shaders, shell-
        // integration scripts, and the xterm-ghostty terminfo
        // database. libghostty resolves these at runtime via the host
        // app's Bundle resourcePath; without them the Settings → Theme
        // picker fails ("not found") and shells under the embedded
        // terminal lose backspace / arrow-key handling because TERM=
        // xterm-ghostty has no terminfo entry to look up. The
        // outputPaths declarations are load-bearing in archive builds:
        // xcodebuild's install phase only copies BuildProducts paths
        // that are declared as build-phase outputs, so a script that
        // writes to Resources/ but doesn't list those entries gets
        // its outputs silently dropped during the install copy
        // (Debug builds skip the install phase entirely, so the
        // problem is invisible until you ship a Release archive).
        .post(
          script: "\"${SRCROOT}/scripts/embed-ghostty-resources.sh\"",
          name: "Embed Ghostty Resources",
          inputPaths: [
            "$(SRCROOT)/.build/ghostty/share/ghostty",
            "$(SRCROOT)/.build/ghostty/share/terminfo",
          ],
          outputPaths: [
            "$(TARGET_BUILD_DIR)/$(UNLOCALIZED_RESOURCES_FOLDER_PATH)/ghostty",
            "$(TARGET_BUILD_DIR)/$(UNLOCALIZED_RESOURCES_FOLDER_PATH)/terminfo",
          ],
          basedOnDependencyAnalysis: false
        ),
      ],
      dependencies: [
        .target(name: "CodansCore"),
        .target(name: "CodansIPC"),
        .target(name: "codans-cli"),
        .target(name: "CodansKit"),
        .target(name: "GhosttyKit"),
        .external(name: "ComposableArchitecture"),
        .external(name: "Sparkle"),
        .external(name: "Sentry"),
      ],
      settings: .settings(
        base: [
          "ENABLE_HARDENED_RUNTIME": "YES",
          "OTHER_LDFLAGS": "$(inherited) -lc++ -framework Carbon -framework Metal -framework MetalKit -framework CoreText -framework QuartzCore",
          "ASSETCATALOG_COMPILER_APPICON_NAME": "AppIcon",
        ],
        defaultSettings: .essential
      )
    ),

    // Codans app unit tests (Runtime + App integration tests).
    .target(
      name: "CodansTests",
      destinations: .macOS,
      product: .unitTests,
      bundleId: "com.gumpw.codans.mac-tests",
      deploymentTargets: .macOS("14.0"),
      infoPlist: .default,
      buildableFolders: [
        "codans/Tests",
        "codans/Tests/Socket",
        "codans/Tests/Harness",
        "codans/Tests/Integration",
        "codans/Tests/GitHubTests",
        "codans/Tests/StatusBarTests",
        "codans/Tests/Shortcuts",
        "codans/Tests/MasterTerminal",
      ],
      dependencies: [
        .target(name: "Codans"),
        .target(name: "CodansKit"),
        .external(name: "SnapshotTesting"),
      ],
      settings: .settings(
        base: [
          "CODE_SIGNING_ALLOWED": "NO",
          "SWIFT_DEFAULT_ACTOR_ISOLATION": "nonisolated",
        ],
        defaultSettings: .essential
      )
    ),
  ],
  additionalFiles: [
    "Configurations/**",
  ],
  resourceSynthesizers: []
)

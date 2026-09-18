// swift-tools-version: 6.0
import PackageDescription

#if TUIST
import ProjectDescription

let packageSettings = PackageSettings(
  productTypes: [
    // Sparkle ships nested XPC services + a Settings.bundle Helper —
    // it must be embedded as a dynamic framework, not statically linked,
    // or its updater won't load at runtime.
    "Sparkle": .framework,
    // Sentry must be a dynamic framework so its crash handler can be
    // installed before main() and its dSYM is uploaded for symbolication.
    "Sentry": .framework,
  ],
  targetSettings: [
    // Xcode 27's `@State` is a macro, and a Debug (incremental) build of
    // Sharing never emits the initializer of `Shared`'s private `@State`
    // that another of its files references: the link fails with an
    // undefined `__generation` symbol. Whole-module compilation emits it
    // (pointfreeco/swift-sharing#240).
    "Sharing": .settings(base: ["SWIFT_COMPILATION_MODE": "wholemodule"])
  ]
)
#endif

let package = Package(
  name: "CodansDependencies",
  dependencies: [
    .package(url: "https://github.com/apple/swift-argument-parser", from: "1.5.0"),
    // Tags carry the generated Web resources, so resolving needs no npm build.
    .package(url: "https://github.com/wanggang316/diff-view", exact: "0.1.4"),
    .package(url: "https://github.com/pointfreeco/swift-composable-architecture", exact: "1.26.2"),
    // Snapshot-testing harness used by view snapshot tests (e.g. TabChip).
    // Resolved eagerly so any future test target can depend on it without
    // re-triggering dependency resolution.
    .package(url: "https://github.com/pointfreeco/swift-snapshot-testing", from: "1.17.0"),
    .package(url: "https://github.com/sparkle-project/Sparkle", exact: "2.9.1"),
    .package(url: "https://github.com/getsentry/sentry-cocoa", from: "9.14.0"),
    // YAML parser for `*.workflow.yaml` definitions (CodansCore/Workflow).
    // Pinned exactly: a floated transitive bump has broken the CI archive before.
    .package(url: "https://github.com/jpsim/Yams", exact: "6.2.2"),
  ]
)

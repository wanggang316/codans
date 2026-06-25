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
  // Tuist's default SwiftPM product type is `.staticFramework`: a static
  // archive wrapped in `Foo.framework`. Xcode 26's CI runner image started
  // scanning those framework modulemaps for pure-Swift macro support modules
  // such as CasePathsMacrosSupport, whose modulemap declares a generated
  // `Foo-Swift.h` that is never produced. Emit package libraries as plain
  // static libraries instead so those framework modulemaps do not exist.
  baseProductType: .staticLibrary
)
#endif

let package = Package(
  name: "CodansDependencies",
  dependencies: [
    .package(url: "https://github.com/apple/swift-argument-parser", from: "1.5.0"),
    .package(url: "https://github.com/pointfreeco/swift-composable-architecture", exact: "1.23.1"),
    // Snapshot-testing harness used by view snapshot tests (e.g. TabChip).
    // Resolved eagerly so any future test target can depend on it without
    // re-triggering dependency resolution.
    .package(url: "https://github.com/pointfreeco/swift-snapshot-testing", from: "1.17.0"),
    .package(url: "https://github.com/sparkle-project/Sparkle", exact: "2.9.1"),
    .package(url: "https://github.com/getsentry/sentry-cocoa", from: "9.14.0"),
  ]
)

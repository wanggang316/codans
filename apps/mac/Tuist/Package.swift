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
  // Two settings, both targeting the same Xcode 26 failure on the
  // macro-support frameworks SwiftPM generates (e.g. CasePathsMacrosSupport,
  // imported by swift-navigation's SwiftNavigationMacros). They are
  // pure-Swift modules with no ObjC interface, yet Xcode builds them as
  // frameworks whose generated module.modulemap declares
  //   header "<Name>-Swift.h"
  // — a Swift→ObjC header that is never produced. On the CI runner the
  // Release archive aborts with "header 'CasePathsMacrosSupport-Swift.h'
  // not found" / "could not build module"; the same source archives fine
  // locally on the identical Xcode 26.0.1 toolchain, so it is environment
  // -timing-sensitive. Command-line build settings on xcodebuild don't
  // reach SwiftPM package targets, so the overrides live here.
  //
  // - SWIFT_INSTALL_OBJC_HEADER=NO: stop emitting/declaring the bogus
  //   -Swift.h so the framework modulemap no longer requires it.
  // - *_ENABLE_EXPLICIT_MODULES=NO: drop the Xcode 26 dependency scanner
  //   that turned the same missing header into 24 scan failures.
  baseSettings: .settings(
    base: [
      "SWIFT_INSTALL_OBJC_HEADER": "NO",
      "SWIFT_ENABLE_EXPLICIT_MODULES": "NO",
      "CLANG_ENABLE_EXPLICIT_MODULES": "NO",
    ]
  )
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

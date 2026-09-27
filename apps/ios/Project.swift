import ProjectDescription

// Orientations are never locked: layout follows size classes, and the
// iPhone Duo inner display ignores supported orientations anyway.
let allOrientations: Plist.Value = [
  "UIInterfaceOrientationPortrait",
  "UIInterfaceOrientationPortraitUpsideDown",
  "UIInterfaceOrientationLandscapeLeft",
  "UIInterfaceOrientationLandscapeRight",
]

let infoPlist: [String: Plist.Value] = [
  "CFBundleDisplayName": "Codans",
  "CFBundleShortVersionString": "$(MARKETING_VERSION)",
  "CFBundleVersion": "$(CURRENT_PROJECT_VERSION)",
  "UILaunchScreen": [:],
  "UIApplicationSceneManifest": [
    "UIApplicationSupportsMultipleScenes": true
  ],
  "UISupportedInterfaceOrientations": allOrientations,
  "UISupportedInterfaceOrientations~ipad": allOrientations,
  "UIRequiresFullScreen": false,
  "NSLocalNetworkUsageDescription":
    "Codans finds and connects to the Codans app on your Mac over the local network.",
  "NSBonjourServices": ["_codans._tcp"],
  "NSCameraUsageDescription": "Codans uses the camera to scan the pairing code shown on your Mac.",
  // The pairing QR code is a `codans-pair:` URL, so the system Camera can
  // hand it to the app; the app confirms before pairing.
  // The Mac's terminal font (ghostty's embedded JetBrainsMono Nerd Font), so
  // prompt and agent glyphs in the Nerd Font private-use range render the
  // same on the phone instead of as missing-glyph boxes.
  "UIAppFonts": [
    "JetBrainsMonoNerdFont-Regular.ttf",
    "JetBrainsMonoNerdFont-Bold.ttf",
    "JetBrainsMonoNerdFont-Italic.ttf",
    "JetBrainsMonoNerdFont-BoldItalic.ttf",
  ],
  "CFBundleURLTypes": [
    [
      "CFBundleURLName": "com.gumpw.codans.mobile.pairing",
      "CFBundleURLSchemes": ["codans-pair"],
    ]
  ],
]

let project = Project(
  name: "CodansMobile",
  // SwiftTerm renders the live pane stream. An Xcode package rather than a
  // Tuist external: Tuist's generated target for it does not build (its
  // build-info plugin), and only this app needs it. The package's plugin
  // makes every xcodebuild invocation pass -skipPackagePluginValidation.
  packages: [
    .remote(url: "https://github.com/migueldeicaza/SwiftTerm", requirement: .exact("1.20.0"))
  ],
  settings: .settings(
    base: [
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
    // The iOS companion: a remote view of a running Mac app over the paired
    // LAN gateway. It links only the platform-clean shared targets from
    // apps/mac — never GhosttyKit, CodansKit or ArgumentParser.
    .target(
      name: "CodansMobile",
      destinations: [.iPhone, .iPad],
      product: .app,
      productName: "Codans",
      bundleId: "com.gumpw.codans.mobile",
      deploymentTargets: .iOS("26.0"),
      infoPlist: .extendingDefault(with: infoPlist),
      resources: [
        // OFL-1.1; the license ships with the fonts.
        "../mac/ThirdParty/ghostty/src/font/res/JetBrainsMonoNerdFont-*.ttf",
        "../mac/ThirdParty/ghostty/src/font/res/OFL.txt",
      ],
      buildableFolders: [
        "CodansMobile/App",
        "CodansMobile/Features/Agents",
        "CodansMobile/Features/Browser",
        "CodansMobile/Features/Composer",
        "CodansMobile/Features/Connection",
        "CodansMobile/Features/PaneDetail",
        "CodansMobile/Features/Settings",
        "CodansMobile/Features/Terminal",
      ],
      dependencies: [
        .project(target: "CodansCore", path: "../mac"),
        .project(target: "CodansIPC", path: "../mac"),
        .project(target: "CodansRemote", path: "../mac"),
        .external(name: "ComposableArchitecture"),
        .package(product: "SwiftTerm"),
      ],
      settings: .settings(
        base: [
          // PRODUCT_NAME is "Codans" (the home-screen and bundle name); keep
          // the Swift module distinct from the Mac app's `Codans` module.
          "PRODUCT_MODULE_NAME": "CodansMobile",
          "TARGETED_DEVICE_FAMILY": "1,2",
          // Ink (black / white), so system controls, menus and alerts
          // never fall back to system blue.
          "ASSETCATALOG_COMPILER_GLOBAL_ACCENT_COLOR_NAME": "AccentColor",
        ],
        defaultSettings: .essential
      )
    ),

    // Reducer tests (TestStore), hosted by the app on a simulator.
    .target(
      name: "CodansMobileTests",
      destinations: [.iPhone, .iPad],
      product: .unitTests,
      bundleId: "com.gumpw.codans.mobile-tests",
      deploymentTargets: .iOS("26.0"),
      infoPlist: .default,
      buildableFolders: ["CodansMobileTests"],
      dependencies: [
        .target(name: "CodansMobile"),
        .project(target: "CodansCore", path: "../mac"),
        .project(target: "CodansIPC", path: "../mac"),
        .external(name: "ComposableArchitecture"),
        .package(product: "SwiftTerm"),
      ],
      settings: .settings(
        base: [
          "CODE_SIGNING_ALLOWED": "NO",
          // An app product does not export its Swift module where a hosted
          // test bundle's import search finds it; point the test target at
          // the app's intermediate module directory so `@testable import
          // CodansMobile` resolves (same fix as the Mac CodansTests target).
          "SWIFT_INCLUDE_PATHS":
            "$(PROJECT_TEMP_DIR)/$(CONFIGURATION)$(EFFECTIVE_PLATFORM_NAME)/CodansMobile.build/Objects-normal/$(NATIVE_ARCH)",
          "SWIFT_DEFAULT_ACTOR_ISOLATION": "nonisolated",
        ],
        defaultSettings: .essential
      )
    ),

    // End-to-end UI test against a live Mac gateway. Skipped unless
    // docs/user-tests/ios-companion/harness.sh passes a pairing code.
    .target(
      name: "CodansMobileUITests",
      destinations: [.iPhone, .iPad],
      product: .uiTests,
      bundleId: "com.gumpw.codans.mobile-uitests",
      deploymentTargets: .iOS("26.0"),
      infoPlist: .default,
      buildableFolders: ["CodansMobileUITests"],
      dependencies: [.target(name: "CodansMobile")],
      settings: .settings(
        base: ["CODE_SIGNING_ALLOWED": "NO", "SWIFT_DEFAULT_ACTOR_ISOLATION": "nonisolated"],
        defaultSettings: .essential
      )
    ),
  ],
  additionalFiles: [
    "Configurations/**"
  ],
  resourceSynthesizers: []
)

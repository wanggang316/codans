import Foundation
import Testing

@testable import CodansCore

struct CLIBundleLocatorTests {
  @Test
  func locateBinaryPrefersResourcesBinOverMacOSSibling() throws {
    let fixture = try AppFixture()
    try fixture.writeExecutable(at: fixture.resourcesTc)
    try fixture.writeExecutable(at: fixture.macosTc)

    let resolved = try CLIBundleLocator.locateBinary(
      executableURL: fixture.appExecutable,
      environment: [:]
    )

    #expect(resolved == fixture.resourcesTc)
  }

  @Test
  func locateBinaryUsesEnvOverrideBeforeBundledResource() throws {
    let fixture = try AppFixture()
    try fixture.writeExecutable(at: fixture.resourcesTc)
    let override = fixture.root.appending(component: "override-tc", directoryHint: .notDirectory)
    try fixture.writeExecutable(at: override)

    let resolved = try CLIBundleLocator.locateBinary(
      executableURL: fixture.appExecutable,
      environment: [CLIBundleLocator.EnvKey.binary: override.path]
    )

    #expect(resolved == override)
  }

  @Test
  func locateBinaryFallsBackToMacOSSiblingWhenResourceIsMissing() throws {
    let fixture = try AppFixture()
    try fixture.writeExecutable(at: fixture.macosTc)

    let resolved = try CLIBundleLocator.locateBinary(
      executableURL: fixture.appExecutable,
      environment: [:]
    )

    #expect(resolved == fixture.macosTc)
  }
}

private final class AppFixture {
  let root: URL
  let appExecutable: URL
  let resourcesTc: URL
  let macosTc: URL

  init() throws {
    root = FileManager.default.temporaryDirectory.appending(
      component: "codans-locator-\(UUID().uuidString)",
      directoryHint: .isDirectory
    )
    let contents =
      root
      .appending(component: "Codans.app", directoryHint: .isDirectory)
      .appending(component: "Contents", directoryHint: .isDirectory)
    let macos = contents.appending(component: "MacOS", directoryHint: .isDirectory)
    let resourcesBin =
      contents
      .appending(component: "Resources", directoryHint: .isDirectory)
      .appending(component: "bin", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: macos, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: resourcesBin, withIntermediateDirectories: true)
    appExecutable = macos.appending(component: "Codans", directoryHint: .notDirectory)
    // The embedded copy carries the channel name; loose products stay `codans`.
    resourcesTc = resourcesBin.appending(
      component: CLIInvocation.commandName, directoryHint: .notDirectory)
    macosTc = macos.appending(component: "codans", directoryHint: .notDirectory)
    try writeExecutable(at: appExecutable)
  }

  deinit {
    try? FileManager.default.removeItem(at: root)
  }

  func writeExecutable(at url: URL) throws {
    try Data("#!/bin/sh\n".utf8).write(to: url)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
  }
}

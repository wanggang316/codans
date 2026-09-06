import Foundation
import Testing

@testable import CodansCore

/// The catalogue is only useful if every other typed holder spells its key
/// through it, and if the catalogue itself is internally consistent.
struct CodansEnvironmentTests {
  @Test
  func keysAreUnique() {
    let raw = CodansEnvironment.Key.allCases.map(\.rawValue)
    #expect(Set(raw).count == raw.count)
  }

  @Test
  func ownKeysCarryTheProductPrefix() {
    let thirdParty: Set<CodansEnvironment.Key> = [
      .zmxDirectory, .zmxSession, .termProgram, .termProgramVersion,
      .ghosttyResourcesDirectory, .terminfoDirectories, .xdgConfigHome,
    ]
    for key in CodansEnvironment.Key.allCases where !thirdParty.contains(key) {
      #expect(key.rawValue.hasPrefix("CODANS_"), "\(key) lacks the CODANS_ prefix")
    }
  }

  @Test
  func olderTypedHoldersSpellThroughTheCatalogue() {
    #expect(BuiltinEnvVar.worktreePath.key == CodansEnvironment.Key.worktreePath.rawValue)
    #expect(BuiltinEnvVar.rootPath.key == CodansEnvironment.Key.rootPath.rawValue)
    #expect(BuiltinEnvVar.reservedKeys == ["CODANS_WORKTREE_PATH", "CODANS_ROOT_PATH"])
    #expect(TermProgramEnv.programKey == CodansEnvironment.Key.termProgram.rawValue)
    #expect(TermProgramEnv.versionKey == CodansEnvironment.Key.termProgramVersion.rawValue)
    #expect(CLIBundleLocator.EnvKey.binary == CodansEnvironment.Key.cliBinary.rawValue)
    #expect(HandoffKickoff.requestIDEnvironmentKey == CodansEnvironment.Key.handoffRequestID.rawValue)
  }

  @Test
  func stripListCoversTheProductMarkerSoItIsRewrittenNotInherited() {
    let strip = Set(CodansEnvironment.inheritedTerminalKeysToStrip)
    #expect(strip.contains("TERM"))
    #expect(strip.contains(CodansEnvironment.Key.termProgram.rawValue))
    #expect(strip.contains(CodansEnvironment.Key.termProgramVersion.rawValue))
  }
}

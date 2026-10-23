import CryptoKit
import Foundation

extension WorkspaceGroupID {
  /// Stable ID for a group that migration or a second app instance must
  /// compute identically: the first 16 bytes of SHA-256 over the key and
  /// the Workspace root.
  public static func derived(rootPath: String, key: String) -> WorkspaceGroupID {
    WorkspaceGroupID(raw: derivedUUID("codans.workspace-group|\(key)|\(rootPath)"))
  }
}

extension WorkspaceMemberID {
  /// Stable ID for a migrated member, derived from the Workspace root and
  /// the member path relative to it.
  public static func derived(rootPath: String, path: String) -> WorkspaceMemberID {
    WorkspaceMemberID(raw: derivedUUID("codans.workspace-member|\(path)|\(rootPath)"))
  }
}

private nonisolated func derivedUUID(_ seed: String) -> UUID {
  let bytes = Array(SHA256.hash(data: Data(seed.utf8)).prefix(16))
  return UUID(
    uuid: (
      bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
      bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]
    ))
}

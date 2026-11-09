import AppKit

/// The one launch alert for a catalog this build loaded with saving off.
/// Without it the user sees an empty or partly restored sidebar and no
/// reason why changes vanish after a restart.
@MainActor
enum CatalogLoadIssueAlert {
  static func present(_ issue: CatalogStore.LoadIssue) {
    let alert = NSAlert()
    alert.alertStyle = .warning
    alert.messageText = messageText(for: issue)
    alert.informativeText = informativeText(for: issue)
    alert.addButton(withTitle: "OK")
    alert.runModal()
  }

  static func messageText(for issue: CatalogStore.LoadIssue) -> String {
    switch issue {
    case .newerVersion:
      return "Created by a newer Codans; changes are not saved"
    case .migrationBackupFailed:
      return "Project list could not be backed up; changes are not saved"
    }
  }

  static func informativeText(for issue: CatalogStore.LoadIssue) -> String {
    switch issue {
    case .newerVersion(let version):
      return "The project list (catalog.json) uses version \(version), which this version of "
        + "Codans cannot read. The file is kept unchanged. Update Codans to use it."
    case .migrationBackupFailed:
      return "Codans updated the project list format, but it could not copy the original "
        + "catalog.json to the backups folder. The original file is kept unchanged and this "
        + "session runs without saving."
    }
  }
}

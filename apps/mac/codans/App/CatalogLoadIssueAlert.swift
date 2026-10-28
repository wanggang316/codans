import AppKit

/// The one launch alert for a catalog this build could not load. Saving
/// is then off, so without it the user sees an empty sidebar and no reason
/// why changes vanish after a restart. A catalog from a newer build shows
/// `CatalogUpdateRequiredView` instead.
@MainActor
enum CatalogLoadIssueAlert {
  static let messageText = "Project list could not be loaded; changes are not saved"
  static let informativeText =
    "Codans could not read or migrate catalog.json. The file is kept unchanged, with a copy "
    + "in the backups folder when one could be made, and this session runs without saving."

  static func present() {
    let alert = NSAlert()
    alert.alertStyle = .warning
    alert.messageText = messageText
    alert.informativeText = informativeText
    alert.addButton(withTitle: "OK")
    alert.runModal()
  }
}

/// The SF Symbol that marks a Project as remote. The sidebar's Remote filter
/// button, the Remote Project markers, and the menu items that act on Remote
/// Projects all read it, so they cannot drift apart. It is not a Host icon:
/// Host rows show the machine through `HostIcon`.
enum RemoteProjectMarker {
  static let symbol = "wifi"
}

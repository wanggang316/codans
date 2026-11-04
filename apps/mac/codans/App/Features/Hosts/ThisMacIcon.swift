import CodansCore
import Foundation
import IOKit

/// The Host icon of This Mac: the symbol of this Mac's model. Read once; the
/// model does not change while the app runs.
nonisolated enum ThisMacIcon {
  static let current: HostIcon = HostIcon.forMacModel(modelName() ?? "")

  /// The product name ("Mac mini (2024)") on Apple silicon, where the model
  /// identifier ("Mac16,10") does not tell the kind of Mac. Intel Macs have
  /// no product name; their identifier ("MacBookPro16,1") does.
  private static func modelName() -> String? {
    productName() ?? sysctlModel()
  }

  private static func productName() -> String? {
    let entry = IORegistryEntryFromPath(kIOMainPortDefault, "IODeviceTree:/product")
    guard entry != MACH_PORT_NULL else { return nil }
    defer { IOObjectRelease(entry) }
    guard
      let data = IORegistryEntryCreateCFProperty(entry, "product-name" as CFString, kCFAllocatorDefault, 0)?
        .takeRetainedValue() as? Data
    else { return nil }
    guard let name = String(bytes: data.prefix { $0 != 0 }, encoding: .utf8), !name.isEmpty else { return nil }
    return name
  }

  private static func sysctlModel() -> String? {
    var size = 0
    guard sysctlbyname("hw.model", nil, &size, nil, 0) == 0, size > 0 else { return nil }
    var bytes = [CChar](repeating: 0, count: size)
    guard sysctlbyname("hw.model", &bytes, &size, nil, 0) == 0 else { return nil }
    return String(cString: bytes)
  }
}

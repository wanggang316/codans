import Foundation
import CodansCore

extension IPC {
  /// Params for `hierarchy.openPane`. `labels` seed the new Pane's label
  /// set; `activate` requests focus after creation.
  public struct PaneOpenRequest: Codable, Equatable, Sendable {
    public let tabID: TabID?
    public let workingDirectory: String?
    public let initialCommand: String?
    public let labels: [String]
    public let activate: Bool

    public init(
      tabID: TabID? = nil,
      workingDirectory: String? = nil,
      initialCommand: String? = nil,
      labels: [String] = [],
      activate: Bool = true
    ) {
      self.tabID = tabID
      self.workingDirectory = workingDirectory
      self.initialCommand = initialCommand
      self.labels = labels
      self.activate = activate
    }
  }
}

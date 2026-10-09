import CodansRemote
import SwiftUI
import VisionKit

/// Full-screen QR scanner for the Mac's pairing code.
struct PairingScannerSheet: View {
  let onCode: (String) -> Void

  @Environment(\.dismiss) private var dismiss

  /// False on the simulator and on devices without a supported camera.
  static var isAvailable: Bool {
    DataScannerViewController.isSupported && DataScannerViewController.isAvailable
  }

  var body: some View {
    NavigationStack {
      PairingScanner(onCode: onCode)
        .ignoresSafeArea(edges: .bottom)
        .navigationTitle("Scan Pairing Code")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
          ToolbarItem(placement: .cancellationAction) {
            Button("Cancel") { dismiss() }
          }
        }
    }
  }
}

/// `DataScannerViewController` restricted to QR codes carrying a
/// `codans-pair:` payload; any other code is ignored.
private struct PairingScanner: UIViewControllerRepresentable {
  let onCode: (String) -> Void

  func makeUIViewController(context: Context) -> DataScannerViewController {
    let scanner = DataScannerViewController(
      recognizedDataTypes: [.barcode(symbologies: [.qr])],
      qualityLevel: .balanced,
      recognizesMultipleItems: false,
      isHighlightingEnabled: true
    )
    scanner.delegate = context.coordinator
    try? scanner.startScanning()
    return scanner
  }

  func updateUIViewController(_ scanner: DataScannerViewController, context: Context) {
    context.coordinator.onCode = onCode
  }

  static func dismantleUIViewController(_ scanner: DataScannerViewController, coordinator: Coordinator) {
    scanner.stopScanning()
  }

  func makeCoordinator() -> Coordinator {
    Coordinator(onCode: onCode)
  }

  final class Coordinator: NSObject, DataScannerViewControllerDelegate {
    var onCode: (String) -> Void
    private var delivered = false

    init(onCode: @escaping (String) -> Void) {
      self.onCode = onCode
    }

    func dataScanner(
      _ dataScanner: DataScannerViewController,
      didAdd addedItems: [RecognizedItem],
      allItems: [RecognizedItem]
    ) {
      guard !delivered else { return }
      for item in addedItems {
        guard case .barcode(let barcode) = item,
          let payload = barcode.payloadStringValue,
          payload.lowercased().hasPrefix("\(PairingPayload.urlScheme):")
        else { continue }
        delivered = true
        dataScanner.stopScanning()
        onCode(payload)
        return
      }
    }
  }
}

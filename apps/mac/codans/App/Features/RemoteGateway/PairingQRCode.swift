import AppKit
import CoreImage
import CoreImage.CIFilterBuiltins

/// Renders a pairing code as a QR image. Error correction `M` keeps the
/// symbol small enough for a phone camera at arm's length; the payload is
/// a few hundred base64url characters.
enum PairingQRCode {
  static func image(for text: String, scale: CGFloat = 8) -> NSImage? {
    let filter = CIFilter.qrCodeGenerator()
    filter.message = Data(text.utf8)
    filter.correctionLevel = "M"
    guard let output = filter.outputImage?.transformed(by: CGAffineTransform(scaleX: scale, y: scale)),
      let cgImage = CIContext().createCGImage(output, from: output.extent)
    else { return nil }
    return NSImage(cgImage: cgImage, size: NSSize(width: output.extent.width, height: output.extent.height))
  }
}

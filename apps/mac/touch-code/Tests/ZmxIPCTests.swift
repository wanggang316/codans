import Foundation
import Testing

@testable import TouchCode

struct ZmxIPCTests {
  @Test
  func encodeDecodeRoundTrip() throws {
    let payload = Data([0x68, 0x65, 0x6c, 0x6c, 0x6f])  // "hello"
    let frame = ZmxFrame(tag: .`init`, payload: payload)
    var buffer = ZmxFraming.encode(frame)

    let decoded = try ZmxFraming.decode(buffer: &buffer)
    #expect(decoded == frame)
    #expect(buffer.isEmpty)
  }

  @Test
  func streamedDecodeYieldsFramesInOrder() throws {
    let frames: [ZmxFrame] = [
      ZmxFrame(tag: .output, payload: Data([0x41])),
      ZmxFrame(tag: .resize, payload: ZmxResizePayload(cols: 80, rows: 24).encode()),
      ZmxFrame(tag: .ack, payload: Data()),
    ]
    var buffer = Data()
    for frame in frames {
      buffer.append(ZmxFraming.encode(frame))
    }

    var decoded: [ZmxFrame] = []
    while let frame = try ZmxFraming.decode(buffer: &buffer) {
      decoded.append(frame)
    }
    #expect(decoded == frames)
    #expect(buffer.isEmpty)
  }

  @Test
  func partialFrameReturnsNilUntilComplete() throws {
    let payload = Data([0xaa, 0xbb, 0xcc, 0xdd])
    let full = ZmxFraming.encode(ZmxFrame(tag: .output, payload: payload))

    // Feed only the first 3 bytes — header is 8, so decode must wait.
    var buffer = Data(full.prefix(3))
    let none = try ZmxFraming.decode(buffer: &buffer)
    #expect(none == nil)

    // Append the rest and try again — the full frame must materialize.
    buffer.append(contentsOf: full.dropFirst(3))
    let frame = try ZmxFraming.decode(buffer: &buffer)
    #expect(frame?.tag == .output)
    #expect(frame?.payload == payload)
    #expect(buffer.isEmpty)
  }

  @Test
  func malformedLengthRejectsOversizedFrame() {
    // Tag = output (1), length = 1 GiB. 8-byte header layout.
    var buffer = Data()
    buffer.append(ZmxTag.output.rawValue)
    var len = UInt32(1024 * 1024 * 1024).littleEndian  // 1 GiB
    withUnsafeBytes(of: &len) { buffer.append(contentsOf: $0) }
    buffer.append(contentsOf: [0, 0, 0])  // padding

    do {
      _ = try ZmxFraming.decode(buffer: &buffer)
      Issue.record("expected payloadTooLarge")
    } catch let error as ZmxIPCError {
      #expect(error == .payloadTooLarge(1024 * 1024 * 1024))
    } catch {
      Issue.record("unexpected error: \(error)")
    }
  }

  @Test
  func unknownTagSurfacesError() {
    // Tag = 0xff (no value defined), length = 0.
    var buffer = Data([0xff, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00])

    do {
      _ = try ZmxFraming.decode(buffer: &buffer)
      Issue.record("expected unknownTag")
    } catch let error as ZmxIPCError {
      #expect(error == .unknownTag(0xff))
    } catch {
      Issue.record("unexpected error: \(error)")
    }
  }

  @Test
  func resizePayloadRoundTrip() throws {
    let payload = ZmxResizePayload(cols: 132, rows: 43)
    let encoded = payload.encode()
    #expect(encoded.count == 4)
    let decoded = try ZmxResizePayload.decode(encoded)
    #expect(decoded == payload)
  }

  @Test
  func infoPayloadDecodesFromFrozenWireShape() throws {
    // Build a 552-byte Info image: pid at offset 8, cwd_len at 14,
    // cwd at 272. Everything else zero.
    var bytes = [UInt8](repeating: 0, count: ZmxInfoPayload.wireSize)
    let pid: Int32 = 4242
    withUnsafeBytes(of: pid.littleEndian) { src in
      for (i, byte) in src.enumerated() {
        bytes[ZmxInfoPayload.pidOffset + i] = byte
      }
    }
    let cwd = "/tmp/touch-code"
    let cwdBytes = Array(cwd.utf8)
    let cwdLen = UInt16(cwdBytes.count).littleEndian
    withUnsafeBytes(of: cwdLen) { src in
      for (i, byte) in src.enumerated() {
        bytes[ZmxInfoPayload.cwdLenOffset + i] = byte
      }
    }
    for (i, byte) in cwdBytes.enumerated() {
      bytes[ZmxInfoPayload.cwdOffset + i] = byte
    }

    let info = try ZmxInfoPayload.decode(Data(bytes))
    #expect(info.pid == 4242)
    #expect(info.cwd == cwd)
  }
}

import Foundation
import Testing

@testable import CodansIPC

struct FramingTests {
  @Test
  func encodeDecodeRoundTrip() throws {
    let body = Data(#"{"id":"x","method":"system.ping"}"#.utf8)
    let frame = try Framing.encode(body)
    var buffer = frame
    let decoded = try Framing.decode(from: &buffer)
    #expect(decoded == body)
    #expect(buffer.isEmpty)
  }

  @Test
  func partialBufferReturnsNilWithoutConsuming() throws {
    let body = Data("hello".utf8)
    let frame = try Framing.encode(body)
    var buffer = frame.prefix(5) // only part of header + body
    let decoded = try Framing.decode(from: &buffer)
    #expect(decoded == nil)
    #expect(buffer.count == 5)
  }

  @Test
  func headerOnlyReturnsNil() throws {
    var buffer = Data([0, 0, 0, 0])
    let decoded = try Framing.decode(from: &buffer)
    #expect(decoded == Data())
  }

  @Test
  func zeroLengthFrameDecodes() throws {
    var buffer = try Framing.encode(Data())
    let decoded = try Framing.decode(from: &buffer)
    #expect(decoded == Data())
    #expect(buffer.isEmpty)
  }

  @Test
  func multipleFramesDecodeInOrder() throws {
    let a = Data("a".utf8)
    let b = Data("bb".utf8)
    var buffer = try Framing.encode(a) + Framing.encode(b)
    let first = try Framing.decode(from: &buffer)
    let second = try Framing.decode(from: &buffer)
    #expect(first == a)
    #expect(second == b)
    #expect(buffer.isEmpty)
  }

  @Test
  func oversizeFrameIsRejectedOnEncode() throws {
    let oversize = Data(count: Int(Framing.maxFrameBytes) + 1)
    #expect(throws: Framing.FramingError.self) {
      _ = try Framing.encode(oversize)
    }
  }

  @Test
  func decodeSurvivesRollingBufferBaseIndex() throws {
    // M1.x follow-up: decode operates on a Data that has had earlier
    // bytes removeSubrange'd, which in Foundation preserves the slice's
    // base index. The raw-bytes `load(as:)` path must read the header
    // from the logical start, not the memory start. Exercise explicitly
    // to prevent a latent regression.
    let a = Data("alpha".utf8)
    let b = Data("bravo".utf8)
    var buffer = try Framing.encode(a) + Framing.encode(b)

    let first = try Framing.decode(from: &buffer)
    #expect(first == a)
    // buffer now has a non-zero logical offset via removeSubrange.
    let second = try Framing.decode(from: &buffer)
    #expect(second == b)
    #expect(buffer.isEmpty)
  }

  @Test
  func oversizeDeclaredLengthIsRejectedOnDecode() throws {
    // Header claims a frame larger than the cap.
    var header = Data(count: 4)
    let bogus = Framing.maxFrameBytes &+ 1
    header[0] = UInt8((bogus >> 24) & 0xFF)
    header[1] = UInt8((bogus >> 16) & 0xFF)
    header[2] = UInt8((bogus >> 8) & 0xFF)
    header[3] = UInt8(bogus & 0xFF)
    var buffer = header
    #expect(throws: Framing.FramingError.self) {
      _ = try Framing.decode(from: &buffer)
    }
  }
}

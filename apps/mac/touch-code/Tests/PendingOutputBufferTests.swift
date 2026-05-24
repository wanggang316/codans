import Foundation
import Testing
import TouchCodeCore

@testable import TouchCode

@MainActor
struct PendingOutputBufferTests {
  @Test
  func coalescesSuccessiveAppendsIntoOneEmission() async throws {
    var emissions: [(PaneID, Data)] = []
    let paneID = PaneID()
    let buffer = PendingOutputBuffer(
      paneID: paneID,
      flushInterval: .milliseconds(20),
      maxBufferSize: 1024
    ) { id, data in
      emissions.append((id, data))
    }

    buffer.append(Data([0x41, 0x42, 0x43]))
    buffer.append(Data([0x44, 0x45]))

    #expect(emissions.isEmpty)

    // Poll instead of sleeping — tolerates scheduler jitter on loaded CI.
    let deadline = Date().addingTimeInterval(1.0)
    while emissions.isEmpty && Date() < deadline {
      try await Task.sleep(for: .milliseconds(5))
    }

    #expect(emissions.count == 1)
    #expect(emissions[0].0 == paneID)
    #expect(emissions[0].1 == Data([0x41, 0x42, 0x43, 0x44, 0x45]))
  }

  @Test
  func immediateFlushWhenBufferExceedsMax() {
    var emissions: [(PaneID, Data)] = []
    let paneID = PaneID()
    let buffer = PendingOutputBuffer(
      paneID: paneID,
      flushInterval: .seconds(10),
      maxBufferSize: 4
    ) { id, data in
      emissions.append((id, data))
    }

    buffer.append(Data([1, 2, 3, 4, 5]))

    #expect(emissions.count == 1)
    #expect(emissions[0].1.count == 5)
  }

  @Test
  func immediateFlushWhenBufferReachesMaxExactly() {
    var emissions: [(PaneID, Data)] = []
    let buffer = PendingOutputBuffer(
      paneID: PaneID(),
      flushInterval: .seconds(10),
      maxBufferSize: 4
    ) { _, data in
      emissions.append((PaneID(), data))
    }

    buffer.append(Data([1, 2, 3, 4]))

    #expect(emissions.count == 1)
    #expect(emissions[0].1.count == 4)
  }

  @Test
  func flushDrainsSynchronously() {
    var emissions: [(PaneID, Data)] = []
    let paneID = PaneID()
    let buffer = PendingOutputBuffer(
      paneID: paneID,
      flushInterval: .seconds(10)
    ) { id, data in
      emissions.append((id, data))
    }

    buffer.append(Data([0xFF]))
    buffer.flush()

    #expect(emissions.count == 1)
    #expect(emissions[0].1 == Data([0xFF]))
  }

  @Test
  func flushOnEmptyBufferEmitsNothing() {
    var emissions: [(PaneID, Data)] = []
    let buffer = PendingOutputBuffer(paneID: PaneID()) { id, data in
      emissions.append((id, data))
    }

    buffer.flush()
    #expect(emissions.isEmpty)
  }
}

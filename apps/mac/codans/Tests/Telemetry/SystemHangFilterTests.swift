import Foundation
import Sentry
import Testing

@testable import Codans

/// Behavioural coverage for `SystemHangFilter`: which events are dropped
/// (all frames in the noise list) and which are kept (any frame outside
/// the noise list, including events with no thread information at all).
struct SystemHangFilterTests {

  private func makeEvent(frameFunctions: [String]) -> Event {
    let event = Event()
    let frames = frameFunctions.map { name -> Frame in
      let frame = Frame()
      frame.function = name
      return frame
    }
    let stacktrace = SentryStacktrace(frames: frames, registers: [:])
    let thread = SentryThread(threadId: NSNumber(value: 0))
    thread.stacktrace = stacktrace
    event.threads = [thread]
    return event
  }

  @Test func dropsEventWhenEveryFrameIsSystemNoise() {
    let event = makeEvent(frameFunctions: [
      "mach_msg2_trap",
      "__CFRunLoopServiceMachPort",
      "_NSMenuBarDisplayManagerActiveSpaceChanged",
    ])
    #expect(SystemHangFilter.filter(event) == nil)
  }

  @Test func keepsEventWhenAnyFrameLooksLikeApp() {
    let event = makeEvent(frameFunctions: [
      "mach_msg2_trap",
      "Codans.PaneCoordinator.render",
      "__CFRunLoopRun",
    ])
    #expect(SystemHangFilter.filter(event) === event)
  }

  @Test func keepsEventWhenThereAreNoStackFrames() {
    let event = Event()
    #expect(SystemHangFilter.filter(event) === event)
  }

  @Test func keepsEventWhenFrameFunctionIsMissing() {
    let event = Event()
    let frame = Frame()
    let stacktrace = SentryStacktrace(frames: [frame], registers: [:])
    let thread = SentryThread(threadId: NSNumber(value: 0))
    thread.stacktrace = stacktrace
    event.threads = [thread]
    #expect(SystemHangFilter.filter(event) === event)
  }
}

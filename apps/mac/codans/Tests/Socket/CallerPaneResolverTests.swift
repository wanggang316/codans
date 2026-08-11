import Darwin
import Foundation
import Testing

@testable import Codans
@testable import CodansCore

@MainActor
struct CallerPaneResolverTests {
  @Test
  func callerItselfIsThePaneShell() {
    let pane = PaneID()
    let resolved = CallerPaneResolver.resolve(
      callerPID: 100,
      paneByShellPID: [100: pane],
      parentOf: { _ in nil }
    )
    #expect(resolved == pane)
  }

  @Test
  func ancestorChainReachesPaneShell() {
    let pane = PaneID()
    // cli(400) → subshell(300) → agent(200) → pane shell(100)
    let parents: [pid_t: pid_t] = [400: 300, 300: 200, 200: 100]
    let resolved = CallerPaneResolver.resolve(
      callerPID: 400,
      paneByShellPID: [100: pane],
      parentOf: { parents[$0] }
    )
    #expect(resolved == pane)
  }

  @Test
  func unrelatedCallerResolvesNil() {
    let parents: [pid_t: pid_t] = [400: 300, 300: 1]
    let resolved = CallerPaneResolver.resolve(
      callerPID: 400,
      paneByShellPID: [100: PaneID()],
      parentOf: { parents[$0] }
    )
    #expect(resolved == nil)
  }

  @Test
  func cyclicParentChainTerminates() {
    let parents: [pid_t: pid_t] = [400: 300, 300: 400]
    let resolved = CallerPaneResolver.resolve(
      callerPID: 400,
      paneByShellPID: [100: PaneID()],
      parentOf: { parents[$0] }
    )
    #expect(resolved == nil)
  }

  @Test
  func emptyMapSkipsTheWalk() {
    var walked = false
    let resolved = CallerPaneResolver.resolve(
      callerPID: 400,
      paneByShellPID: [:],
      parentOf: { _ in
        walked = true
        return nil
      }
    )
    #expect(resolved == nil)
    #expect(!walked)
  }

  @Test
  func kernelParentLookupMatchesGetppid() {
    #expect(CallerPaneResolver.parentPID(of: getpid()) == getppid())
  }

  @Test
  func kernelParentLookupReturnsNilForDeadPID() {
    // PID max on Darwin is 99998; beyond it no process can exist.
    #expect(CallerPaneResolver.parentPID(of: 999_999) == nil)
  }

  @Test
  func kernelWalkResolvesViaRealAncestry() {
    // Register the test runner's parent as a pane shell; the default
    // sysctl-backed walk must attribute this process to it. Under
    // xcodebuild the test host is spawned directly by launchd (ppid 1),
    // which the walk correctly refuses to match — nothing real to
    // register there, so only assert with a live parent chain.
    let parent = getppid()
    guard parent > 1 else { return }
    let pane = PaneID()
    let resolved = CallerPaneResolver.resolve(
      callerPID: getpid(),
      paneByShellPID: [parent: pane]
    )
    #expect(resolved == pane)
  }
}

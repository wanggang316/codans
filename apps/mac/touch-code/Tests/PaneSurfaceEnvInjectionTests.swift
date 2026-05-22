import Foundation
import Testing
import TouchCodeCore

@testable import TouchCode

/// Unit coverage for the pure C-string conversion that PaneSurface uses to
/// hand env vars to libghostty. Spawning a real PaneSurface requires a live
/// `GhosttyRuntime` (which boots libghostty + an NSView host) — too heavy for
/// a unit test. The string allocation is the only piece that can leak or
/// corrupt memory, so we exercise it directly and free pointers in tearDown.
@MainActor
struct PaneSurfaceEnvInjectionTests {
  @Test
  func emptyEnvProducesEmptyArray() {
    let pairs = PaneSurface.makeEnvCStrings([:])
    #expect(pairs.isEmpty)
    // No pointers to free — empty input takes the fast path.
  }

  @Test
  func nonEmptyEnvAllocatesOnePairPerEntry() {
    let env = ["A": "1", "B": "2", "C": "3"]
    let pairs = PaneSurface.makeEnvCStrings(env)
    defer {
      for pair in pairs {
        free(UnsafeMutableRawPointer(pair.key))
        free(UnsafeMutableRawPointer(pair.value))
      }
    }
    #expect(pairs.count == env.count)
  }

  @Test
  func keysAndValuesRoundTripThroughCStrings() {
    let env = ["MY_VAR": "hello", "PROJECT_ROOT": "/tmp/example"]
    let pairs = PaneSurface.makeEnvCStrings(env)
    defer {
      for pair in pairs {
        free(UnsafeMutableRawPointer(pair.key))
        free(UnsafeMutableRawPointer(pair.value))
      }
    }
    var roundTripped: [String: String] = [:]
    for pair in pairs {
      let key = String(cString: pair.key)
      let value = String(cString: pair.value)
      roundTripped[key] = value
    }
    #expect(roundTripped == env)
  }

  @Test
  func entriesAreSortedByKeyForDeterministicLayout() {
    // Sorted iteration order keeps the buffer layout stable, which keeps the
    // test surface predictable when (or if) future tests compare buffer
    // contents at specific indices.
    let env = ["zebra": "z", "apple": "a", "mango": "m"]
    let pairs = PaneSurface.makeEnvCStrings(env)
    defer {
      for pair in pairs {
        free(UnsafeMutableRawPointer(pair.key))
        free(UnsafeMutableRawPointer(pair.value))
      }
    }
    let keys = pairs.map { String(cString: $0.key) }
    #expect(keys == ["apple", "mango", "zebra"])
  }

  @Test
  func unicodeKeysAndValuesRoundTrip() {
    // strdup is byte-oriented; UTF-8-encoded multi-byte sequences must
    // survive the round-trip without corruption.
    let env = ["GREETING": "héllo 世界", "EMOJI_KEY": "🎉"]
    let pairs = PaneSurface.makeEnvCStrings(env)
    defer {
      for pair in pairs {
        free(UnsafeMutableRawPointer(pair.key))
        free(UnsafeMutableRawPointer(pair.value))
      }
    }
    var roundTripped: [String: String] = [:]
    for pair in pairs {
      let key = String(cString: pair.key)
      let value = String(cString: pair.value)
      roundTripped[key] = value
    }
    #expect(roundTripped == env)
  }
}

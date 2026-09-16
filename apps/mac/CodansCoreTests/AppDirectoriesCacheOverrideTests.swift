import CodansCore
import Foundation
import Testing

struct AppDirectoriesCacheOverrideTests {
  @Test func explicitCacheRootIsIsolated() {
    #expect(AppDirectories.cacheDirectory(override: "/tmp/codans-diff-qa/cache").path == "/tmp/codans-diff-qa/cache")
  }

  @Test func emptyOverrideKeepsChannelDefault() {
    #expect(AppDirectories.cacheDirectory(override: "") == AppDirectories.cacheDirectory(override: nil))
    #expect(AppDirectories.cacheDirectory(override: nil).lastPathComponent == AppDirectories.name)
  }
}

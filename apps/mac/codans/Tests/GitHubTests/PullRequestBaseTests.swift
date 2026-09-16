import CodansCore
import Foundation
import Testing

@testable import Codans

struct PullRequestBaseTests {
  @Test
  func parserPreservesBaseRepositorySeparatelyFromForkHead() throws {
    let data = Data(
      #"{"data":{"repository":{"branch0":{"nodes":[{"number":42,"headRefName":"feature","baseRefName":"release/v2","baseRepository":{"url":"https://github.com/upstream/repository"},"headRepository":{"owner":{"login":"fork-owner"}}}]}}}}"#
        .utf8
    )
    let result = try JSONOutputParsers.parseBatchedPullRequests(
      data, aliasMap: ["branch0": "feature"], remoteOwner: "fork-owner"
    )
    let snapshot = try #require(result["feature"])
    #expect(snapshot.baseRefName == "release/v2")
    #expect(snapshot.baseRepositoryURL == URL(string: "https://github.com/upstream/repository"))
    #expect(snapshot.headRepositoryOwner == "fork-owner")
    let encoded = try JSONEncoder().encode(snapshot)
    #expect(try JSONDecoder().decode(PullRequestSnapshot.self, from: encoded) == snapshot)
    var legacy = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
    legacy.removeValue(forKey: "baseRefName")
    legacy.removeValue(forKey: "baseRepositoryURL")
    let decoded = try JSONDecoder().decode(
      PullRequestSnapshot.self, from: JSONSerialization.data(withJSONObject: legacy)
    )
    #expect(decoded.number == snapshot.number)
    #expect(decoded.baseRefName == nil)
    #expect(decoded.baseRepositoryURL == nil)
  }

  @Test
  func sparseGraphQLDoesNotInventBaseRepository() throws {
    let data = Data(
      #"{"data":{"repository":{"branch0":{"nodes":[{"number":42,"headRepository":{"owner":{"login":"owner"}}}]}}}}"#
        .utf8
    )
    let result = try JSONOutputParsers.parseBatchedPullRequests(
      data, aliasMap: ["branch0": "feature"], remoteOwner: "owner"
    )
    let snapshot = try #require(result["feature"])
    #expect(snapshot.baseRefName == nil)
    #expect(snapshot.baseRepositoryURL == nil)
  }
}

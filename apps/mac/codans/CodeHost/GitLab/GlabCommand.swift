import CodansCore
import Foundation

/// Argv builder for every `glab` invocation the GitLab Code Host issues. Each static
/// function returns the complete argument vector (without the `glab` executable path)
/// together with the exit codes that reach the caller's happy-path parsing; any other
/// code goes to `GitLabCodeHost`'s error translation.
///
/// Every repository-scoped call names its host explicitly: `--hostname <host>` when the
/// host has no port, and always `GITLAB_HOST=<host>` in the subprocess env (see
/// `GitLabCodeHost.makeEnv`), because `glab --hostname` rejects `host:port`. User input
/// (branch names, project paths, numbers) is always one argv element: branch names go
/// into a JSON array variable, never into the query text.
///
/// Tests lock every argv list, as for `GhCommand`.
nonisolated enum GlabCommand {
  typealias Command = (arguments: [String], expectedExitCodes: Set<Int32>)

  /// `glab version`. Prints `glab 1.128.0 (519ea19f7)`; older releases print
  /// `glab version 1.22.0 (2022-01-01)`.
  static func version() -> Command {
    (["version"], [0])
  }

  /// `glab auth status --all --output json`. Exit 1 when any configured host fails its
  /// check, with the JSON still on stdout, so both 0 and 1 reach the parser.
  static func authStatus() -> Command {
    (["auth", "status", "--all", "--output", "json"], [0, 1])
  }

  /// `glab api graphql [--hostname <host>] -f query=<body> -f <k>=<v> … -F <k>=<json> …`.
  /// `stringVariables` are sent as strings (`-f`); `jsonVariables` hold JSON values
  /// (`-F`, which parses a value that starts with `[` or `{`). Both are sorted so argv
  /// stays deterministic.
  ///
  /// Exit 0 → GraphQL response. Exit 1 → `glab` failure, or a GraphQL `errors` body on
  /// stdout; the caller inspects both.
  static func apiGraphQL(
    query: String,
    host: String,
    stringVariables: [String: String] = [:],
    jsonVariables: [String: String] = [:]
  ) -> Command {
    var args = ["api", "graphql"] + hostnameArguments(host) + ["-f", "query=\(query)"]
    for key in stringVariables.keys.sorted() {
      args += ["-f", "\(key)=\(stringVariables[key] ?? "")"]
    }
    for key in jsonVariables.keys.sorted() {
      args += ["-F", "\(key)=\(jsonVariables[key] ?? "")"]
    }
    return (args, [0])
  }

  /// `glab api --method PUT projects/<id>/merge_requests/<iid>/merge -F squash=<bool>`.
  /// The project's merge method applies; codans only chooses whether to squash.
  static func mergeRequestMerge(
    repository: CodeHostRepository, iid: Int, squash: Bool
  ) -> Command {
    rest(
      method: "PUT", path: "\(mergeRequestPath(repository, iid: iid))/merge", host: repository.host,
      fields: ["-F", "squash=\(squash)"])
  }

  /// `glab api --method PUT projects/<id>/merge_requests/<iid> -f state_event=close`.
  static func mergeRequestClose(repository: CodeHostRepository, iid: Int) -> Command {
    rest(
      method: "PUT", path: mergeRequestPath(repository, iid: iid), host: repository.host,
      fields: ["-f", "state_event=close"])
  }

  /// `glab api projects/<id>/merge_requests/<iid>`: the merge request, for its
  /// `head_pipeline.id`.
  static func mergeRequestView(repository: CodeHostRepository, iid: Int) -> Command {
    rest(method: "GET", path: mergeRequestPath(repository, iid: iid), host: repository.host, fields: [])
  }

  /// `glab api --method POST projects/<id>/pipelines/<pipeline id>/retry`. GitLab
  /// retries the failed and canceled jobs of the pipeline only.
  static func pipelineRetry(repository: CodeHostRepository, pipelineID: Int64) -> Command {
    rest(
      method: "POST", path: "projects/\(GitLab.projectID(repository))/pipelines/\(pipelineID)/retry",
      host: repository.host, fields: [])
  }

  /// GraphQL mutation that marks a draft merge request ready. The REST API has no
  /// draft flag; it would need a title rewrite.
  static let markReadyMutation = """
    mutation($projectPath: ID!, $iid: String!) {
      mergeRequestSetDraft(input: {projectPath: $projectPath, iid: $iid, draft: false}) {
        errors
        mergeRequest { draft }
      }
    }
    """

  // MARK: - Private

  private static func mergeRequestPath(_ repository: CodeHostRepository, iid: Int) -> String {
    "projects/\(GitLab.projectID(repository))/merge_requests/\(iid)"
  }

  private static func rest(method: String, path: String, host: String, fields: [String]) -> Command {
    (["api", path, "--method", method] + hostnameArguments(host) + fields, [0])
  }

  private static func hostnameArguments(_ host: String) -> [String] {
    GitLab.hostHasPort(host) ? [] : ["--hostname", host]
  }
}

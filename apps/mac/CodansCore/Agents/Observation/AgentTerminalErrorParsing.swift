import Foundation

/// Shared ordering and value decoding. Each provider still owns its banner and
/// activity grammar, so adding a provider never broadens another one's matches.
nonisolated enum AgentTerminalErrorParsing {
  static func parse(
    _ text: String, promptPrefixes: [String],
    activity: (String) -> AgentObservedActivity,
    banner: (String) -> String?
  ) -> TerminalParseResult {
    let visible = Set(
      AgentObservationText.unquotedLines(text).compactMap(banner).map { ErrorBannerSignature(value: $0) })
    let lines = AgentObservationText.interactionLines(text, promptPrefixes: promptPrefixes)
    let input = AgentObservationText.inputAvailability(lines, prefixes: promptPrefixes)
    let lastError = lines.indices.last(where: { banner(lines[$0]) != nil })
    let lastRetry = lines.indices.last(where: { isProviderRetry(lines[$0]) })
    let live = latestActivity(lines, classify: activity)

    if let index = lastError, index > (lastRetry ?? -1), index > (live?.index ?? -1),
      let message = banner(lines[index]),
      hasOnlyComposer(after: index, lines: lines, promptPrefixes: promptPrefixes)
    {
      return .error(
        failure: failure(message), banner: .init(value: message),
        inputAvailability: input, visibleErrorBanners: visible)
    }
    if let index = lastRetry, index > (lastError ?? -1), index >= (live?.index ?? -1),
      hasOnlyComposer(after: index, lines: lines, promptPrefixes: promptPrefixes)
    {
      return .working(visibleErrorBanners: visible)
    }
    if let live, live.index > (lastError ?? -1), live.index >= (lastRetry ?? -1) {
      return live.activity == .blocked
        ? .blocked(visibleErrorBanners: visible) : .working(visibleErrorBanners: visible)
    }
    if case .prompt = input { return .idle(inputAvailability: input, visibleErrorBanners: visible) }
    return .unknown(visibleErrorBanners: visible)
  }

  private static func latestActivity(
    _ lines: [String], classify: (String) -> AgentObservedActivity
  ) -> (index: Int, activity: AgentObservedActivity)? {
    var latest: (Int, AgentObservedActivity)?
    for index in lines.indices {
      let result = classify(lines[index...].joined(separator: "\n"))
      if result == .working || result == .blocked { latest = (index, result) }
    }
    return latest
  }

  private static func hasOnlyComposer(after index: Int, lines: [String], promptPrefixes: [String]) -> Bool {
    lines.dropFirst(index + 1).allSatisfy {
      $0.isEmpty || AgentObservationText.isBorder($0)
        || AgentObservationText.promptContent($0, prefixes: promptPrefixes) != nil
    }
  }

  private static func isProviderRetry(_ line: String) -> Bool {
    let lower = line.lowercased()
    let content = lower.hasPrefix("⎿ ") ? String(lower.dropFirst(2)).trimmingCharacters(in: .whitespaces) : lower
    return content.hasPrefix("retrying") || content.hasPrefix("reconnecting")
      || content.hasPrefix("attempting to reconnect") || content.hasPrefix("retry in ")
  }

  static func failure(_ message: String) -> AgentFailure {
    let lower = message.lowercased()
    let code = lower.range(of: #"\b[45][0-9]{2}\b"#, options: .regularExpression).map { String(lower[$0]) }
    let configurationFailure = ["invalid model", "configuration"].contains(where: lower.contains)
    let reason: AgentFailure.Reason
    if ["insufficient_quota", "usage limit", "quota", "credit balance", "billing"].contains(where: lower.contains) {
      reason = .quotaExceeded
    } else if ["401", "403"].contains(code)
      || ["unauthorized", "authentication", "invalid api key"].contains(where: lower.contains)
    {
      reason = .authentication
    } else if code == "429" || lower.contains("rate limit") || lower.contains("rate_limit") {
      reason = .rateLimited
    } else if ["400", "404", "422"].contains(code) || configurationFailure {
      reason = .configuration
    } else if code?.hasPrefix("5") == true
      || ["timeout", "timed out", "stream disconnected", "exceeded retry limit", "overloaded", "connection reset"]
        .contains(where: lower.contains)
    {
      reason = .transient
    } else {
      reason = .unknown
    }
    return AgentFailure(reason: reason, message: message, providerCode: code, retryAfterSeconds: retryAfter(lower))
  }

  private static func retryAfter(_ text: String) -> Int? {
    guard let range = text.range(of: #"retry[- ]after[:= ]+[0-9]+"#, options: .regularExpression) else { return nil }
    let token = text[range].split(whereSeparator: { !$0.isNumber }).last
    return token.flatMap { Int($0) }
  }
}

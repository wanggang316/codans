import Foundation

/// Checks a `codans workflow deliver` body against the step's `expect`.
///
/// Two tiers, on purpose: `rejections` are what the pipeline cannot use at
/// all (an empty body, an oversized one, a verdict outside the declared
/// set) and always refuse the delivery; `issues` are the author's declared
/// contract (required sections, format, a verdict that was declared but not
/// given) and are what `strict` decides about — rejected outright under
/// `strict: true`, otherwise kept as a provisional delivery for the user to
/// accept, ask again about, or skip.
public nonisolated enum WorkflowDeliveryValidator {
  /// 16 MiB — matches the IPC frame cap.
  public static let maximumBodyBytes = 16 * 1024 * 1024

  public struct Result: Equatable, Sendable {
    /// The body with chat wrapping stripped (`MarkdownDocumentNormalizer`)
    /// for markdown, trimmed for the other formats. Persisted as-is.
    public var normalizedBody: String
    public var rejection: Rejection?
    public var issues: [Issue]

    public var isRejected: Bool { rejection != nil }
    public var isClean: Bool { rejection == nil && issues.isEmpty }
  }

  public enum Rejection: Equatable, Sendable {
    case emptyBody
    case bodyTooLarge(bytes: Int)
    case unknownVerdict(String, allowed: [String])

    /// Stable code for the CLI envelope.
    public var code: String {
      switch self {
      case .emptyBody: return "OUTPUT_INVALID"
      case .bodyTooLarge: return "OUTPUT_TOO_LARGE"
      case .unknownVerdict: return "OUTPUT_INVALID"
      }
    }

    public var message: String {
      switch self {
      case .emptyBody:
        return "the delivery body is empty"
      case .bodyTooLarge(let bytes):
        return "the delivery body is \(bytes) bytes; the limit is \(WorkflowDeliveryValidator.maximumBodyBytes)"
      case .unknownVerdict(let verdict, let allowed):
        return "verdict \"\(verdict)\" is not one of: \(allowed.joined(separator: ", "))"
      }
    }
  }

  public enum Issue: Equatable, Sendable {
    case missingSections([String])
    case verdictRequired(allowed: [String])
    case invalidJSON(String)

    /// Stable code; `VERDICT_REQUIRED` / `OUTPUT_INVALID` when strict.
    public var code: String {
      switch self {
      case .missingSections: return "OUTPUT_INVALID"
      case .verdictRequired: return "VERDICT_REQUIRED"
      case .invalidJSON: return "OUTPUT_INVALID"
      }
    }

    public var message: String {
      switch self {
      case .missingSections(let sections):
        return "missing section(s): \(sections.joined(separator: ", "))"
      case .verdictRequired(let allowed):
        return "a verdict is required: --verdict \(allowed.joined(separator: "|"))"
      case .invalidJSON(let detail):
        return "the body is not valid JSON: \(detail)"
      }
    }
  }

  public static func validate(body: String, verdict: String?, expectation: WorkflowExpectation) -> Result {
    let bytes = body.utf8.count
    if bytes > maximumBodyBytes {
      return Result(normalizedBody: "", rejection: .bodyTooLarge(bytes: bytes), issues: [])
    }
    let normalized: String
    switch expectation.format {
    case .markdown:
      normalized = MarkdownDocumentNormalizer.normalized(body)
    case .text, .json:
      normalized = body.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    if normalized.isEmpty {
      return Result(normalizedBody: "", rejection: .emptyBody, issues: [])
    }
    if let verdict, let allowed = expectation.verdicts, !allowed.contains(verdict) {
      return Result(normalizedBody: normalized, rejection: .unknownVerdict(verdict, allowed: allowed), issues: [])
    }

    var issues: [Issue] = []
    if expectation.format == .markdown, !expectation.sections.isEmpty {
      let missing = MarkdownDocumentNormalizer.missingSections(expectation.sections, in: normalized)
      if !missing.isEmpty { issues.append(.missingSections(missing)) }
    }
    if expectation.format == .json {
      do {
        _ = try JSONSerialization.jsonObject(with: Data(normalized.utf8), options: [.fragmentsAllowed])
      } catch {
        issues.append(.invalidJSON(error.localizedDescription))
      }
    }
    if let allowed = expectation.verdicts, verdict == nil {
      issues.append(.verdictRequired(allowed: allowed))
    }
    return Result(normalizedBody: normalized, rejection: nil, issues: issues)
  }
}

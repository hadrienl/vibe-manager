import Foundation

/// Part of a field's value, kept by a regular expression: `{{url|/merge_requests\/(\d+)/}}` gives
/// `1315` out of a merge request's URL.
///
/// The first match, or its first group when the pattern has one — a group is what lets a pattern
/// say where the part is without being part of it. A value the pattern does not match gives
/// nothing: refusing it would stop a session over a URL that is merely shaped differently, so the
/// form says it instead.
public struct PromptTemplateExtraction: Hashable, Sendable {
  public let pattern: String

  public init(pattern: String) {
    self.pattern = pattern
  }

  public enum Outcome: Hashable, Sendable {
    case extracted(String)
    case noMatch
    /// The pattern is not a regular expression; the sentence says why.
    case invalid(String)
  }

  /// Why the pattern cannot be used, or `nil` when it can.
  public var problem: String? {
    if case .invalid(let reason) = apply(to: "") { return reason }
    return nil
  }

  public func apply(to value: String) -> Outcome {
    let expression: NSRegularExpression
    do {
      expression = try NSRegularExpression(pattern: pattern)
    } catch {
      return .invalid(Self.reason(error))
    }
    guard !value.isEmpty else { return .extracted("") }
    let whole = NSRange(value.startIndex..., in: value)
    guard let match = expression.firstMatch(in: value, range: whole) else { return .noMatch }
    var range = match.range
    if match.numberOfRanges > 1, match.range(at: 1).location != NSNotFound {
      range = match.range(at: 1)
    }
    guard let found = Range(range, in: value) else { return .noMatch }
    return .extracted(String(value[found]))
  }

  private static func reason(_ error: any Error) -> String {
    let description = (error as NSError).localizedFailureReason
    guard let description, !description.isEmpty else {
      return String(localized: "It is not a valid regular expression.", bundle: .module)
    }
    return description
  }
}

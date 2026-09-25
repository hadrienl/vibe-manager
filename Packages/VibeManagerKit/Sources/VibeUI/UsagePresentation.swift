import Foundation
import VibeDomain

/// How usage figures read. Pure, so the wording can be held to in tests.
enum UsagePresentation {
  static var tokensExplanation: String {
    String(
      localized: """
        Tokens are read from the transcripts Claude Code and Codex write on this Mac. They are \
        approximate: a transcript the CLI deletes can no longer be read, an interrupted answer may \
        be written without its usage, calls the CLI makes outside its transcript are not seen, and \
        sessions started outside Vibe Manager are never counted.
        """,
      bundle: .module)
  }
  static var costExplanation: String {
    String(
      localized: """
        Neither CLI reports a cost that holds together: Claude Code's running totals go down as \
        well as up, and Codex reports none. A price list shipped with the application would be \
        wrong within weeks, and means nothing on a subscription.
        """,
      bundle: .module)
  }
  static var runningTimeExplanation: String {
    String(
      localized: """
        The time the agent's process was running in Vibe Manager, whether it was working or \
        waiting for you. Time the Mac spent asleep is not counted.
        """,
      bundle: .module)
  }
  static var privacyNote: String {
    String(
      localized: "Usage is recorded on this Mac only. Nothing is sent anywhere.", bundle: .module)
  }

  static func duration(_ seconds: TimeInterval) -> String {
    let minutes = Int((seconds / 60).rounded(.down))
    if minutes < 1 { return seconds > 0 ? "< 1 min" : "0 min" }
    let hours = minutes / 60
    let rest = minutes % 60
    if hours == 0 { return "\(rest) min" }
    return rest == 0 ? "\(hours) h" : "\(hours) h \(rest) min"
  }

  static func tokens(_ value: Int) -> String {
    switch value {
    case ..<1_000: return "\(value)"
    case ..<1_000_000: return trimmed(Double(value) / 1_000) + " k"
    default: return trimmed(Double(value) / 1_000_000) + " M"
    }
  }

  private static func trimmed(_ value: Double) -> String {
    value >= 100 ? String(format: "%.0f", value) : String(format: "%.1f", value)
  }

  /// "2 starts · 5 resumes (2 after relaunch) · 1 new process · 1 switch".
  static func runs(_ counts: UsageRunCounts) -> String {
    guard counts.total > 0 else {
      return String(
        localized: "None recorded", bundle: .module, comment: "No run of an agent was recorded.")
    }
    var parts: [String] = []
    if counts.starts > 0 {
      parts.append(
        String(
          localized: "\(counts.starts) starts", bundle: .module,
          comment: "How many times an agent was started for the first time."))
    }
    if counts.resumes > 0 {
      parts.append(
        String(
          localized: "\(counts.resumes) resumes", bundle: .module,
          comment: "How many times an agent resumed its conversation."))
    }
    if counts.restarts > 0 {
      parts.append(
        String(
          localized: "\(counts.restarts) new processes", bundle: .module,
          comment: "How many times an agent was restarted without resuming its conversation."))
    }
    var sentence = parts.joined(separator: " · ")
    if counts.afterRelaunch > 0 {
      sentence += String(
        localized: " (\(counts.afterRelaunch) after relaunch)", bundle: .module,
        comment:
          "How many of the resumes followed a relaunch of Vibe Manager. Keep the leading space.")
    }
    if counts.afterSwitch > 0 {
      sentence +=
        " · "
        + String(
          localized: "\(counts.afterSwitch) switches", bundle: .module,
          comment: "How many times the session's agent was switched.")
    }
    return sentence
  }

  static func tokenSummary(_ tokens: TokenCounts) -> String {
    var parts = [
      String(
        localized: "\(Self.tokens(tokens.input)) in", bundle: .module,
        comment: "Input tokens, abbreviated: “12.3 k in”."),
      String(
        localized: "\(Self.tokens(tokens.output)) out", bundle: .module,
        comment: "Output tokens, abbreviated: “4.5 k out”."),
    ]
    if tokens.cacheRead > 0 {
      parts.append(
        String(
          localized: "\(Self.tokens(tokens.cacheRead)) cache read", bundle: .module,
          comment: "Tokens read from the cache, abbreviated: “1.2 M cache read”."))
    }
    if tokens.cacheWrite > 0 {
      parts.append(
        String(
          localized: "\(Self.tokens(tokens.cacheWrite)) cache write", bundle: .module,
          comment: "Tokens written to the cache, abbreviated: “80.0 k cache write”."))
    }
    return parts.joined(separator: " · ")
  }

  static func unavailable(_ reason: UsageUnavailability) -> String {
    switch reason {
    case .notReportedByAgent:
      return String(
        localized: "Not reported by this agent", bundle: .module,
        comment: "Why a usage figure is missing.")
    case .noTranscript:
      return String(
        localized: "No transcript found", bundle: .module, comment: "Why a usage figure is missing."
      )
    case .notReliable:
      return String(
        localized: "Not available", bundle: .module, comment: "Why a usage figure is missing.")
    case .trackingOff:
      return String(
        localized: "Usage tracking is off", bundle: .module,
        comment: "Why a usage figure is missing.")
    }
  }

  static func periodName(_ period: UsagePeriod) -> LocalizedStringResource {
    switch period {
    case .today:
      return LocalizedStringResource(
        "Today", bundle: .module, comment: "A period of the Usage window.")
    case .last7Days:
      return LocalizedStringResource(
        "Last 7 days", bundle: .module, comment: "A period of the Usage window.")
    case .last30Days:
      return LocalizedStringResource(
        "Last 30 days", bundle: .module, comment: "A period of the Usage window.")
    case .thisMonth:
      return LocalizedStringResource(
        "This month", bundle: .module, comment: "A period of the Usage window.")
    case .previousMonth:
      return LocalizedStringResource(
        "Previous month", bundle: .module, comment: "A period of the Usage window.")
    case .allTime:
      return LocalizedStringResource(
        "All time", bundle: .module, comment: "A period of the Usage window.")
    }
  }

  static func groupingName(_ grouping: UsageGrouping) -> LocalizedStringResource {
    switch grouping {
    case .session:
      return LocalizedStringResource(
        "Session", bundle: .module, comment: "What the Usage window groups its figures by.")
    case .provider:
      return LocalizedStringResource(
        "Agent", bundle: .module, comment: "What the Usage window groups its figures by.")
    case .model:
      return LocalizedStringResource(
        "Model", bundle: .module,
        comment: "What the Usage window groups its figures by: an agent's model.")
    }
  }
}

import Foundation
import VibeDomain

/// How usage figures read. Pure, so the wording can be held to in tests.
enum UsagePresentation {
  static let tokensExplanation = """
    Tokens are read from the transcripts Claude Code and Codex write on this Mac. They are \
    approximate: a transcript the CLI deletes can no longer be read, an interrupted answer may be \
    written without its usage, calls the CLI makes outside its transcript are not seen, and \
    sessions started outside Vibe Manager are never counted.
    """
  static let costExplanation = """
    Neither CLI reports a cost that holds together: Claude Code's running totals go down as well \
    as up, and Codex reports none. A price list shipped with the application would be wrong \
    within weeks, and means nothing on a subscription.
    """
  static let runningTimeExplanation = """
    The time the agent's process was running in Vibe Manager, whether it was working or waiting \
    for you. Time the Mac spent asleep is not counted.
    """
  static let privacyNote = "Usage is recorded on this Mac only. Nothing is sent anywhere."

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
    guard counts.total > 0 else { return "None recorded" }
    var parts: [String] = []
    if counts.starts > 0 { parts.append(plural(counts.starts, "start")) }
    if counts.resumes > 0 { parts.append(plural(counts.resumes, "resume")) }
    if counts.restarts > 0 { parts.append(plural(counts.restarts, "new process", "new processes")) }
    var sentence = parts.joined(separator: " · ")
    if counts.afterRelaunch > 0 { sentence += " (\(counts.afterRelaunch) after relaunch)" }
    if counts.afterSwitch > 0 {
      sentence += " · " + plural(counts.afterSwitch, "switch", "switches")
    }
    return sentence
  }

  static func tokenSummary(_ tokens: TokenCounts) -> String {
    var parts = ["\(Self.tokens(tokens.input)) in", "\(Self.tokens(tokens.output)) out"]
    if tokens.cacheRead > 0 { parts.append("\(Self.tokens(tokens.cacheRead)) cache read") }
    if tokens.cacheWrite > 0 { parts.append("\(Self.tokens(tokens.cacheWrite)) cache write") }
    return parts.joined(separator: " · ")
  }

  static func unavailable(_ reason: UsageUnavailability) -> String {
    switch reason {
    case .notReportedByAgent: return "Not reported by this agent"
    case .noTranscript: return "No transcript found"
    case .notReliable: return "Not available"
    case .trackingOff: return "Usage tracking is off"
    }
  }

  static func periodName(_ period: UsagePeriod) -> String {
    switch period {
    case .today: return "Today"
    case .last7Days: return "Last 7 days"
    case .last30Days: return "Last 30 days"
    case .thisMonth: return "This month"
    case .previousMonth: return "Previous month"
    case .allTime: return "All time"
    }
  }

  static func groupingName(_ grouping: UsageGrouping) -> String {
    switch grouping {
    case .session: return "Session"
    case .provider: return "Agent"
    case .model: return "Model"
    }
  }

  private static func plural(_ count: Int, _ singular: String, _ plural: String? = nil) -> String {
    "\(count) " + (count == 1 ? singular : (plural ?? singular + "s"))
  }
}

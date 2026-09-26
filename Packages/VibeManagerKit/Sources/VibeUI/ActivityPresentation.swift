import Foundation
import SwiftUI
import VibeApplication
import VibeDomain

/// What the Activity pane says, decided without a view so that it can be tested (#36).
enum ActivityPresentation {
  /// Where the summary stands, in words: never an empty block.
  enum SummaryStatus: Equatable {
    case disabled
    case noJournal
    case waitingForFirstTurn
    case unavailable(JournalSummaryUnavailability)
    case failed(at: Date)
    case normal
  }

  static func summaryStatus(
    journal: SessionJournal?, session: WorkSession, summariesEnabled: Bool
  ) -> SummaryStatus {
    guard let journal else {
      return session.status == .active ? .waitingForFirstTurn : .noJournal
    }
    if case .unavailable(let reason) = journal.summary { return .unavailable(reason) }
    if !summariesEnabled { return .disabled }
    if case .failed(let at, _) = journal.summary { return .failed(at: at) }
    if journal.entries.isEmpty, !journal.hasEndedTurn { return .waitingForFirstTurn }
    return .normal
  }

  static func sentence(for status: SummaryStatus, agentName: String) -> String? {
    switch status {
    case .normal:
      return nil
    case .disabled:
      return String(localized: "Automatic summary is turned off.", bundle: .module)
    case .noJournal:
      return String(localized: "No journal for this session.", bundle: .module)
    case .waitingForFirstTurn:
      return String(
        localized: "The summary will start when the agent finishes its first turn.",
        bundle: .module)
    case .unavailable(.unsupported):
      return String(
        localized: "\(agentName) cannot summarize this session: it offers no way to.",
        bundle: .module, comment: "An agent's name.")
    case .unavailable(.outdated):
      return String(
        localized:
          "\(agentName) cannot summarize this session: its command-line tool is too old.",
        bundle: .module, comment: "An agent's name.")
    case .unavailable(.signedOut):
      return String(
        localized: "\(agentName) cannot summarize this session: it is not signed in.",
        bundle: .module, comment: "An agent's name.")
    case .unavailable(.missing):
      return String(
        localized:
          "\(agentName) cannot summarize this session: its command-line tool cannot be run.",
        bundle: .module, comment: "An agent's name.")
    case .failed(let at):
      return String(
        localized:
          "The last summary could not be written, at \(at.formatted(date: .omitted, time: .shortened)).",
        bundle: .module, comment: "A time of day.")
    }
  }

  // MARK: - Entries

  /// The entries shown, the latest `limit`, with a day before the first of each day when they span
  /// several.
  enum EntryRow: Identifiable, Equatable {
    case day(Date)
    case entry(JournalEntry)

    var id: String {
      switch self {
      case .day(let date): return "day-\(date.timeIntervalSinceReferenceDate)"
      case .entry(let entry): return entry.id.uuidString
      }
    }
  }

  static func entryRows(
    _ entries: [JournalEntry], limit: Int, calendar: Calendar = .current
  ) -> (rows: [EntryRow], hidden: Int) {
    let shown = entries.suffix(limit)
    let spansDays =
      Set(entries.map { calendar.startOfDay(for: $0.at) }).count > 1
    var rows: [EntryRow] = []
    var lastDay: Date?
    for entry in shown {
      let day = calendar.startOfDay(for: entry.at)
      if spansDays, day != lastDay {
        rows.append(.day(day))
        lastDay = day
      }
      rows.append(.entry(entry))
    }
    return (rows, entries.count - shown.count)
  }

  static func entryText(_ entry: JournalEntry) -> String {
    if let count = entry.foldedCount {
      return String(
        localized: "\(count) older actions", bundle: .module,
        comment: "Stands for journal entries folded away; a count.")
    }
    return entry.text
  }

  private static let detector = try? NSDataDetector(
    types: NSTextCheckingResult.CheckingType.link.rawValue)

  /// The web links of a text, as `NSDataDetector` finds them in the notes.
  static func links(in text: String) -> [URL] {
    guard let detector else { return [] }
    return detector.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap {
      guard let url = $0.url, let scheme = url.scheme?.lowercased(),
        scheme == "http" || scheme == "https"
      else { return nil }
      return url
    }
  }

  /// An entry with its links clickable, a link to a known resource shown by its short name.
  static func attributedText(
    _ entry: JournalEntry, resources: [SessionResource]
  ) -> AttributedString {
    let text = entryText(entry)
    guard entry.foldedCount == nil, let detector else { return AttributedString(text) }
    var result = AttributedString()
    var cursor = text.startIndex
    for match in detector.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
      guard let url = match.url, let scheme = url.scheme?.lowercased(),
        scheme == "http" || scheme == "https", let range = Range(match.range, in: text)
      else { continue }
      result += AttributedString(text[cursor..<range.lowerBound])
      var link = AttributedString(shortName(of: url, resources: resources) ?? String(text[range]))
      link.link = url
      result += link
      cursor = range.upperBound
    }
    result += AttributedString(text[cursor...])
    return result
  }

  /// `!1315` for the URL of a merge request the session used.
  static func shortName(of url: URL, resources: [SessionResource]) -> String? {
    guard let key = ResourceRecognizer.resource(for: url, involvement: .viewed, at: Date())?.key,
      let resource = resources.first(where: { $0.key == key })
    else { return nil }
    return resource.label
  }

  // MARK: - Resources

  static let groups: [SessionResource.Kind] = [.issue, .pullRequest, .branch, .worktree]

  static func groupTitle(_ kind: SessionResource.Kind) -> LocalizedStringResource {
    switch kind {
    case .issue:
      return LocalizedStringResource("Issues", bundle: .module, comment: "A group of resources.")
    case .pullRequest:
      return LocalizedStringResource(
        "Pull & Merge Requests", bundle: .module, comment: "A group of resources.")
    case .branch:
      return LocalizedStringResource("Branches", bundle: .module, comment: "A group of resources.")
    case .worktree:
      return LocalizedStringResource("Worktrees", bundle: .module, comment: "A group of resources.")
    }
  }

  static func symbol(_ kind: SessionResource.Kind) -> String {
    switch kind {
    case .issue: return "smallcircle.filled.circle"
    case .pullRequest: return "arrow.triangle.pull"
    case .branch: return "arrow.triangle.branch"
    case .worktree: return "folder"
    }
  }

  static func isMergeRequest(_ resource: SessionResource) -> Bool {
    resource.key.hasPrefix("gitlab:") && resource.kind == .pullRequest
  }

  /// The involvement in words, agreeing with the resource in languages where it must.
  static func involvement(_ resource: SessionResource) -> String {
    switch (resource.kind, resource.involvement) {
    case (.issue, .created):
      return String(
        localized: "involvement.issue.created", defaultValue: "created", bundle: .module)
    case (.issue, .changed):
      return String(
        localized: "involvement.issue.changed", defaultValue: "changed", bundle: .module)
    case (.issue, .viewed):
      return String(localized: "involvement.issue.viewed", defaultValue: "viewed", bundle: .module)
    case (.pullRequest, .created):
      return String(
        localized: "involvement.request.created", defaultValue: "created", bundle: .module)
    case (.pullRequest, .changed):
      return String(
        localized: "involvement.request.changed", defaultValue: "changed", bundle: .module)
    case (.pullRequest, .viewed):
      return String(
        localized: "involvement.request.viewed", defaultValue: "viewed", bundle: .module)
    case (.branch, .created):
      return String(
        localized: "involvement.branch.created", defaultValue: "created", bundle: .module)
    case (.branch, .changed):
      return String(
        localized: "involvement.branch.changed", defaultValue: "changed", bundle: .module)
    case (.branch, .viewed):
      return String(
        localized: "involvement.branch.viewed", defaultValue: "checked out", bundle: .module)
    case (.worktree, .created):
      return String(
        localized: "involvement.worktree.created", defaultValue: "created", bundle: .module)
    case (.worktree, .changed):
      return String(
        localized: "involvement.worktree.changed", defaultValue: "worked in", bundle: .module)
    case (.worktree, .viewed):
      return String(
        localized: "involvement.worktree.viewed", defaultValue: "visited", bundle: .module)
    }
  }

  /// What VoiceOver reads: "Pull request #62, hadrienl/vibe-manager, created".
  static func spokenLabel(_ resource: SessionResource) -> String {
    [spokenName(resource), resource.context, involvement(resource)].compactMap { $0 }.joined(
      separator: ", ")
  }

  /// A resource named with its kind: "Pull request #62", "Branch feat/36-journal".
  static func spokenName(_ resource: SessionResource) -> String {
    let label = resource.label
    switch resource.kind {
    case .issue:
      return String(
        localized: "Issue \(label)", bundle: .module, comment: "A ticket's short name: #36.")
    case .pullRequest where isMergeRequest(resource):
      return String(
        localized: "Merge request \(label)", bundle: .module, comment: "A request's short name.")
    case .pullRequest:
      return String(
        localized: "Pull request \(label)", bundle: .module, comment: "A request's short name.")
    case .branch:
      return String(
        localized: "Branch \(label)", bundle: .module, comment: "A branch's name.")
    case .worktree:
      return String(
        localized: "Worktree \(label)", bundle: .module, comment: "A worktree's folder name.")
    }
  }

  /// `hadrienl/vibe-manager#36`, `group/project!12`: a reference a forge understands.
  static func reference(_ resource: SessionResource) -> String {
    guard let context = resource.context else { return resource.label }
    return context + resource.label
  }

  /// What ⌘C copies.
  static func copyText(_ resource: SessionResource) -> String {
    switch resource.target {
    case .web(let url): return url.absoluteString
    case .branch: return resource.label
    case .folder(let path): return path
    }
  }
}

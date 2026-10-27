import Foundation
import VibeDomain

/// A report as words, in the user's language (#408): the totals' line, a session's dates, and
/// the whole report in Markdown for a team's meeting or a progress message.
public struct ArchiveReportText: Sendable {
  public var locale: Locale
  public var calendar: Calendar

  public init(locale: Locale = .current, calendar: Calendar = .autoupdatingCurrent) {
    self.locale = locale
    var calendar = calendar
    calendar.locale = locale
    self.calendar = calendar
  }

  /// “6 sessions · 3 pull requests created · 5 tickets touched · 4 branches · 7 h 20 min”: the
  /// parts at zero are left out, but the sessions.
  public func totals(_ totals: ArchiveReport.Totals) -> String {
    var parts = [
      String(
        localized: "\(totals.sessions) sessions", bundle: .module, locale: locale,
        comment: "Archive report totals: how many sessions were archived.")
    ]
    if totals.pullRequestsCreated > 0 {
      parts.append(
        String(
          localized: "\(totals.pullRequestsCreated) pull requests created", bundle: .module,
          locale: locale, comment: "Archive report totals."))
    }
    if totals.ticketsTouched > 0 {
      parts.append(
        String(
          localized: "\(totals.ticketsTouched) tickets touched", bundle: .module, locale: locale,
          comment: "Archive report totals: tickets the sessions changed or created."))
    }
    if totals.branches > 0 {
      parts.append(
        String(
          localized: "\(totals.branches) branches", bundle: .module, locale: locale,
          comment: "Archive report totals: branches the sessions created or changed."))
    }
    if totals.runningTime >= 60 {
      parts.append(
        String(
          localized: "\(duration(totals.runningTime)) running", bundle: .module, locale: locale,
          comment: "Archive report totals: how long the agents ran. The argument is a duration."))
    }
    return parts.joined(separator: " · ")
  }

  /// “7 h 20 min”.
  public func duration(_ interval: TimeInterval) -> String {
    let formatter = DateComponentsFormatter()
    formatter.calendar = calendar
    formatter.unitsStyle = .abbreviated
    formatter.allowedUnits = interval >= 3600 ? [.hour, .minute] : [.minute]
    formatter.zeroFormattingBehavior = .dropAll
    return formatter.string(from: max(interval, 60)) ?? ""
  }

  /// “Started Mon 09:12 · finished Tue 17:40”.
  public func dates(of session: ArchivedSessionSnapshot) -> String {
    let style = Date.FormatStyle(
      date: .omitted, time: .shortened, locale: locale, calendar: calendar
    )
    .weekday(.abbreviated)
    var parts: [String] = []
    if let started = session.startedAt {
      parts.append(
        String(
          localized: "started \(started.formatted(style))", bundle: .module, locale: locale,
          comment:
            "Archive report: when a session first went In Progress. The argument is a day and time."
        ))
    }
    if let finished = session.finishedAt {
      parts.append(
        String(
          localized: "finished \(finished.formatted(style))", bundle: .module, locale: locale,
          comment:
            "Archive report: when a session last arrived in Done. The argument is a day and time."))
    }
    return parts.joined(separator: " · ")
  }

  /// “Unarchived on 3 Oct”.
  public func unarchived(_ date: Date) -> String {
    let day = date.formatted(.dateTime.day().month(.abbreviated).locale(locale))
    return String(
      localized: "Unarchived on \(day)", bundle: .module, locale: locale,
      comment:
        "Archive report: the user took this session out of the archive since. The argument is a day."
    )
  }

  public func olderEntries(_ count: Int) -> String {
    String(
      localized: "and \(count) older entries", bundle: .module, locale: locale,
      comment: "Archive report: journal sentences written before the period, folded away.")
  }

  public var noProject: String {
    String(
      localized: "No Group", bundle: .module, locale: locale,
      comment: "Archive report: the heading of sessions outside any group of the sidebar.")
  }

  /// What a resource's line says it did.
  public func involvement(_ resource: SessionResource) -> String {
    switch resource.involvement {
    case .created:
      String(
        localized: "created", bundle: .module, locale: locale,
        comment: "Archive report: a session created this ticket, pull request or branch.")
    case .changed:
      String(
        localized: "changed", bundle: .module, locale: locale,
        comment: "Archive report: a session changed this ticket, pull request or branch.")
    case .viewed:
      String(
        localized: "viewed", bundle: .module, locale: locale,
        comment: "Archive report: a session only looked at this ticket or pull request.")
    }
  }

  /// The report in Markdown: a heading per project, a line per session, its sentences, its
  /// resources with their links.
  public func markdown(_ report: ArchiveReport, title: String, synthesis: String? = nil) -> String {
    var lines = ["# \(Self.escaped(title))", "", totals(report.totals)]
    if let synthesis, !synthesis.isEmpty {
      lines += ["", Self.escaped(synthesis)]
    }
    for project in report.projects {
      lines += ["", "## \(Self.escaped(project.name ?? noProject))", ""]
      for session in project.sessions {
        var header = "- **\(Self.escaped(session.snapshot.name))**"
        let dates = dates(of: session.snapshot)
        if !dates.isEmpty { header += " — \(dates)" }
        if let running = session.snapshot.runningTime, running >= 60 {
          header += " · \(duration(running))"
        }
        if let unarchivedAt = session.unarchivedAt { header += " · \(unarchived(unarchivedAt))" }
        lines.append(header)
        for entry in session.entries { lines.append("  - \(Self.escaped(entry.text))") }
        if session.olderEntryCount > 0 {
          lines.append("  - _\(olderEntries(session.olderEntryCount))_")
        }
        for resource in session.snapshot.workedResources {
          let label = Self.escaped(resource.label)
          let context = resource.context.map { " (\(Self.escaped($0)))" } ?? ""
          let link = Self.webURL(of: resource).map { "[\(label)](\($0.absoluteString))" } ?? label
          lines.append("  - \(link)\(context) — \(involvement(resource))")
        }
      }
    }
    return lines.joined(separator: "\n") + "\n"
  }

  /// The address a resource opens at, `http` and `https` only.
  public static func webURL(of resource: SessionResource) -> URL? {
    let url: URL? =
      switch resource.target {
      case .web(let url): url
      case .branch(_, let webURL): webURL
      case .folder: nil
      }
    guard let url, let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https"
    else { return nil }
    return url
  }

  /// Text that Markdown reads as it is written: a session's name never makes a heading or a link.
  static func escaped(_ text: String) -> String {
    var result = ""
    for character in text.replacingOccurrences(of: "\n", with: " ") {
      if "\\`*_[]<>#|".contains(character) { result.append("\\") }
      result.append(character)
    }
    return result
  }
}

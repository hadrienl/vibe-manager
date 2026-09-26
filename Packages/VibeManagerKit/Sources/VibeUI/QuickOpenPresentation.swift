import Foundation
import SwiftUI
import VibeApplication
import VibeDomain

/// What Open Quickly says, decided without a view so that it can be tested (#37).
enum QuickOpenPresentation {
  /// Why a session is listed, in words, on the second line of its row.
  static func reason(_ reason: QuickOpenReason) -> String? {
    switch reason {
    case .resource(let kind, let label, let context, let involvement):
      let resource = described(kind: kind, label: label, context: context, involvement: involvement)
      var parts = [ActivityPresentation.spokenName(resource), context].compactMap { $0 }
      if involvement != nil { parts.append(ActivityPresentation.involvement(resource)) }
      return parts.joined(separator: " · ")
    case .title:
      return String(
        localized: "Title", bundle: .module,
        comment: "Why a session is listed in Open Quickly: its title matches.")
    case .folder(let path):
      return String(
        localized: "Folder \(abbreviated(path))", bundle: .module,
        comment: "Why a session is listed in Open Quickly: a folder's path.")
    case .summary(let excerpt):
      return String(
        localized: "Summary: \(excerpt)", bundle: .module,
        comment: "Why a session is listed in Open Quickly: a piece of its summary.")
    case .notes(let excerpt):
      return String(
        localized: "Notes: \(excerpt)", bundle: .module,
        comment: "Why a session is listed in Open Quickly: a piece of its notes.")
    case .recent:
      return nil
    }
  }

  /// What VoiceOver reads for a reason: the resource named in full.
  static func spokenReason(_ reason: QuickOpenReason) -> String? {
    guard case .resource(let kind, let label, let context, let involvement) = reason else {
      return self.reason(reason)
    }
    let resource = described(kind: kind, label: label, context: context, involvement: involvement)
    guard involvement != nil else {
      return [ActivityPresentation.spokenName(resource), context].compactMap { $0 }
        .joined(separator: ", ")
    }
    return ActivityPresentation.spokenLabel(resource)
  }

  /// A resource the palette describes with the words of the Activity pane. A GitLab merge request
  /// is told by its `!`.
  private static func described(
    kind: SessionResource.Kind, label: String, context: String?,
    involvement: SessionResource.Involvement?
  ) -> SessionResource {
    SessionResource(
      key: label.hasPrefix("!") ? "gitlab:" : "", kind: kind, label: label, context: context,
      target: .folder(""), involvement: involvement ?? .viewed, firstSeenAt: .distantPast)
  }

  static func abbreviated(_ path: String) -> String {
    (path as NSString).abbreviatingWithTildeInPath
  }

  /// A whole row, for VoiceOver: "Quick open, In Progress, Pull request #62, o/r, created,
  /// archived, 2 of 5".
  static func spokenRow(
    title: String, state: String, reason: QuickOpenReason, isArchived: Bool, position: Int,
    count: Int
  ) -> String {
    var parts = [title, state]
    if let reason = spokenReason(reason) { parts.append(reason) }
    if isArchived { parts.append(archivedLabel) }
    parts.append(
      String(
        localized: "\(position) of \(count)", bundle: .module,
        comment: "A result's position in Open Quickly, then how many there are."))
    return parts.joined(separator: ", ")
  }

  static var archivedLabel: String {
    String(
      localized: "Archived", bundle: .module,
      comment: "A tag on a session of Open Quickly that is archived.")
  }

  static func countAnnouncement(_ count: Int) -> String {
    count == 0
      ? String(
        localized: "No results", bundle: .module,
        comment: "Said by VoiceOver when Open Quickly finds nothing.")
      : String(
        localized: "\(count) results", bundle: .module,
        comment: "Said by VoiceOver: how many sessions Open Quickly found.")
  }

  /// The empty state: what was typed matched nothing.
  static func noMatch(_ text: String) -> String {
    String(
      localized: "No session matches “\(text)”.", bundle: .module,
      comment: "Open Quickly found nothing for what was typed.")
  }

  /// A ticket or request understood, and used by no session.
  static func unused(_ reason: QuickOpenReason) -> String? {
    guard case .resource(let kind, let label, let context, _) = reason else { return nil }
    let resource = described(kind: kind, label: label, context: context, involvement: nil)
    let name = [ActivityPresentation.spokenName(resource), context].compactMap { $0 }.joined(
      separator: " · ")
    return String(
      localized: "No session used \(name).", bundle: .module,
      comment: "Open Quickly understood a ticket or request URL: its short name.")
  }

  /// What can be typed, under the recent sessions and when nothing matches.
  static var formats: String {
    String(
      localized:
        "Type a ticket (#36, owner/repo#36), a pull or merge request URL, a branch, a folder or a title.",
      bundle: .module, comment: "The help of Open Quickly. Keep the examples as they are.")
  }

  static func indexing(done: Int, total: Int) -> String {
    String(
      localized: "Reading journals… (\(done) of \(total))", bundle: .module,
      comment: "Open Quickly is still reading the sessions' journals at launch.")
  }

  /// `text` with the words typed set in bold, wherever they are, without case or accents.
  static func highlighted(_ text: String, words: [String]) -> AttributedString {
    var attributed = AttributedString(text)
    let options: String.CompareOptions = [
      .caseInsensitive, .diacriticInsensitive, .widthInsensitive,
    ]
    for word in words where !word.isEmpty {
      var searchRange = text.startIndex..<text.endIndex
      while let found = text.range(of: word, options: options, range: searchRange) {
        if let lower = AttributedString.Index(found.lowerBound, within: attributed),
          let upper = AttributedString.Index(found.upperBound, within: attributed)
        {
          attributed[lower..<upper].inlinePresentationIntent = .stronglyEmphasized
        }
        guard found.upperBound < text.endIndex else { break }
        searchRange = found.upperBound..<text.endIndex
      }
    }
    return attributed
  }
}

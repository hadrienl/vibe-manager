import Foundation

/// The resolvers shipped with the application (#89): changed or switched off by the user as they
/// wish. One left alone follows the revisions a later version ships.
public enum TicketResolverPresets {
  public static let github = TicketResolver(
    id: UUID(uuidString: "6E4B2D8A-5C1F-4E0B-9A7D-1B0C3F2E5A01")!,
    name: "GitHub",
    pattern:
      #"https://(www\.)?github\.com/(?<owner>[A-Za-z0-9_.-]+)/(?<repo>[A-Za-z0-9_.-]+)/(issues|pull)/(?<number>[0-9]+)"#,
    shortID: "{owner}/{repo}#{number}",
    titleCleanup: [
      // "Title by someone · Pull Request #12 · owner/repo"
      #" by [^ ]+ · Pull Request #[0-9]+ · [^·]+$"#,
      #" · (Issue|Pull Request) #[0-9]+ · [^·]+$"#,
      #" · GitHub$"#,
    ],
    preset: .init(id: "github", revision: 1))

  public static let gitlabIssues = TicketResolver(
    id: UUID(uuidString: "6E4B2D8A-5C1F-4E0B-9A7D-1B0C3F2E5A02")!,
    name: "GitLab",
    pattern:
      #"https://gitlab\.com/(?<project>[A-Za-z0-9_.-]+(/[A-Za-z0-9_.-]+)+)/-/(issues|work_items)/(?<number>[0-9]+)"#,
    shortID: "{project}#{number}",
    // "Title (#42) · Issues · Group / Project · GitLab"
    titleCleanup: [#" \(#[0-9]+\)( · .*)?$"#, #" · GitLab$"#],
    preset: .init(id: "gitlab-issues", revision: 1))

  public static let gitlabMergeRequests = TicketResolver(
    id: UUID(uuidString: "6E4B2D8A-5C1F-4E0B-9A7D-1B0C3F2E5A03")!,
    name: "GitLab Merge Requests",
    pattern:
      #"https://gitlab\.com/(?<project>[A-Za-z0-9_.-]+(/[A-Za-z0-9_.-]+)+)/-/merge_requests/(?<number>[0-9]+)"#,
    shortID: "{project}!{number}",
    titleCleanup: [#" \(![0-9]+\)( · .*)?$"#, #" · GitLab$"#],
    preset: .init(id: "gitlab-merge-requests", revision: 1))

  public static let jiraCloud = TicketResolver(
    id: UUID(uuidString: "6E4B2D8A-5C1F-4E0B-9A7D-1B0C3F2E5A04")!,
    name: "Jira Cloud",
    pattern:
      #"https://(?<site>[A-Za-z0-9-]+)\.atlassian\.net/browse/(?<key>[A-Za-z][A-Za-z0-9_]*-[0-9]+)"#,
    shortID: "{key}",
    // "[PROJ-123] Summary - Jira"
    titleCleanup: [#"^\[[^\]]+\] "#, #" - Jira$"#, #"^Jira$"#],
    preset: .init(id: "jira-cloud", revision: 1))

  public static let linear = TicketResolver(
    id: UUID(uuidString: "6E4B2D8A-5C1F-4E0B-9A7D-1B0C3F2E5A05")!,
    name: "Linear",
    pattern:
      #"https://linear\.app/(?<workspace>[A-Za-z0-9_-]+)/issue/(?<key>[A-Za-z0-9]+-[0-9]+)"#,
    shortID: "{key}",
    // "ENG-123 Title", "Title | Linear"
    titleCleanup: [#"^[A-Za-z0-9]+-[0-9]+ "#, #" [|–-] Linear$"#],
    preset: .init(id: "linear", revision: 1))

  /// In the order they are listed and tried.
  public static let all = [github, gitlabIssues, gitlabMergeRequests, jiraCloud, linear]

  public static func shipped(id: String) -> TicketResolver? {
    all.first { $0.preset?.id == id }
  }

  /// The resolvers to use, from what was stored: a preset left alone takes the shipped revision,
  /// one the user never saw is added at the end, and one the user deleted stays deleted.
  ///
  /// - Parameters:
  ///   - stored: the resolvers as they were saved, in their order.
  ///   - knownPresets: the presets that already existed when they were saved.
  public static func merge(stored: [TicketResolver], knownPresets: Set<String>) -> [TicketResolver]
  {
    var result = stored.map { resolver -> TicketResolver in
      guard let origin = resolver.preset, !origin.isModified,
        let shipped = shipped(id: origin.id),
        let shippedRevision = shipped.preset?.revision, shippedRevision > origin.revision
      else { return resolver }
      var updated = resolver
      updated.pattern = shipped.pattern
      updated.shortID = shipped.shortID
      updated.titleCleanup = shipped.titleCleanup
      updated.preset = shipped.preset
      return updated
    }
    for preset in all {
      guard let id = preset.preset?.id, !knownPresets.contains(id),
        !result.contains(where: { $0.preset?.id == id })
      else { continue }
      result.append(preset)
    }
    return result
  }

  /// The resolver, marked as changed by the user when its rules differ from the shipped ones.
  public static func markingChanges(_ resolver: TicketResolver) -> TicketResolver {
    guard let origin = resolver.preset, let shipped = shipped(id: origin.id) else {
      return resolver
    }
    var marked = resolver
    marked.preset?.isModified =
      !(resolver.sameRules(as: shipped) && origin.revision == shipped.preset?.revision)
    return marked
  }

  /// The shipped rules again, keeping the user's name and switch.
  public static func restoring(_ resolver: TicketResolver) -> TicketResolver {
    guard let origin = resolver.preset, let shipped = shipped(id: origin.id) else {
      return resolver
    }
    var restored = shipped
    restored.id = resolver.id
    restored.isEnabled = resolver.isEnabled
    return restored
  }
}

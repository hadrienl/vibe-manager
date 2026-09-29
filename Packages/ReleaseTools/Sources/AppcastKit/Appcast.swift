import Foundation

/// A release that is in the feed.
public struct AppcastEntry: Equatable, Sendable {
  public var release: GitHubRelease
  public var item: AppcastItem
  public var version: ReleaseVersion
  public var build: BuildNumber
  public var archiveURL: String
  /// `unstable` for a prerelease, `nil` for a final version: Sparkle offers an item without a
  /// channel to everyone.
  public var channel: String? { release.prerelease ? "unstable" : nil }
}

public enum AppcastError: Error, Equatable, CustomStringConvertible {
  case malformedReleases(String)
  case malformedItem(tag: String, String)
  case tagMismatch(tag: String, version: String)
  case invalidVersion(tag: String, version: String)
  case invalidBuild(tag: String, build: String)
  case archiveNotZip(tag: String, archive: String)
  case lengthMismatch(tag: String, archive: String, length: Int, size: Int)
  case invalidPublicationDate(tag: String, String)

  public var description: String {
    switch self {
    case .malformedReleases(let reason):
      "the releases are not a list of GitHub releases: \(reason)"
    case .malformedItem(let tag, let reason):
      "\(tag): the appcast item is not readable: \(reason)"
    case .tagMismatch(let tag, let version):
      "\(tag): the appcast item describes version \(version), not the tag's"
    case .invalidVersion(let tag, let version):
      "\(tag): \(version) is not a semantic version"
    case .invalidBuild(let tag, let build):
      "\(tag): the build \(build) is not a number, or numbers separated by dots"
    case .archiveNotZip(let tag, let archive):
      "\(tag): the archive \(archive) is not a .zip"
    case .lengthMismatch(let tag, let archive, let length, let size):
      "\(tag): the appcast item gives \(length) bytes, the asset \(archive) has \(size)"
    case .invalidPublicationDate(let tag, let date):
      "\(tag): the publication date \(date) is not ISO 8601"
    }
  }
}

/// The Sparkle feed, computed in full from the published releases (ADR 0033). Nothing is kept
/// from a previous feed: unpublishing a release takes it out.
public enum Appcast {
  /// How many versions of each channel the feed keeps, the most recent ones.
  public static let entriesPerChannel = 10

  public struct Result: Sendable {
    public var entries: [AppcastEntry]
    /// Why each release left out was, for the log.
    public var skipped: [String]
    public var xml: String
  }

  /// - Parameters:
  ///   - releases: the releases of the repository, drafts included.
  ///   - items: the `.appcast.json` of each release, keyed by tag.
  public static func generate(releases: [GitHubRelease], items: [String: Data]) throws -> Result {
    var entries: [AppcastEntry] = []
    var skipped: [String] = []
    // A draft is never read: it is not in the feed by construction, whatever it holds.
    for release in releases where !release.draft {
      switch try entry(for: release, itemData: items[release.tagName]) {
      case .success(let entry): entries.append(entry)
      case .failure(let reason): skipped.append("\(release.tagName): \(reason.message)")
      }
    }
    let selected = select(entries)
    return Result(entries: selected, skipped: skipped, xml: AppcastWriter.xml(for: selected))
  }

  public static func generate(releasesJSON: Data, items: [String: Data]) throws -> Result {
    try generate(releases: GitHubRelease.decodeList(from: releasesJSON), items: items)
  }

  /// The most recent first: by build, then, for one build, the final version before its
  /// candidates, and `rc.10` before `rc.9`.
  static func precedes(_ lhs: AppcastEntry, _ rhs: AppcastEntry) -> Bool {
    if lhs.build != rhs.build { return lhs.build > rhs.build }
    if lhs.version != rhs.version { return lhs.version > rhs.version }
    return lhs.release.tagName < rhs.release.tagName
  }

  static func select(_ entries: [AppcastEntry]) -> [AppcastEntry] {
    var finals = 0
    var prereleases = 0
    return entries.sorted(by: precedes).filter { entry in
      if entry.release.prerelease {
        prereleases += 1
        return prereleases <= entriesPerChannel
      }
      finals += 1
      return finals <= entriesPerChannel
    }
  }

  private struct Skip: Error {
    var message: String
  }

  /// A release without its archive or its item is left out; one whose item contradicts it is an
  /// error, since what it would publish is not what was built.
  private static func entry(
    for release: GitHubRelease, itemData: Data?
  ) throws -> Swift.Result<AppcastEntry, Skip> {
    let tag = release.tagName
    guard let itemData else { return .failure(Skip(message: "no appcast item, left out")) }
    let item: AppcastItem
    do {
      item = try JSONDecoder().decode(AppcastItem.self, from: itemData)
    } catch {
      throw AppcastError.malformedItem(tag: tag, String(describing: error))
    }
    guard tag == "v\(item.version)" else {
      throw AppcastError.tagMismatch(tag: tag, version: item.version)
    }
    guard let version = ReleaseVersion(item.version) else {
      throw AppcastError.invalidVersion(tag: tag, version: item.version)
    }
    guard let build = BuildNumber(item.build) else {
      throw AppcastError.invalidBuild(tag: tag, build: item.build)
    }
    guard item.archive.hasSuffix(".zip") else {
      throw AppcastError.archiveNotZip(tag: tag, archive: item.archive)
    }
    guard let asset = release.assets.first(where: { $0.name == item.archive }) else {
      return .failure(Skip(message: "no asset \(item.archive), left out"))
    }
    guard asset.size == item.length else {
      throw AppcastError.lengthMismatch(
        tag: tag, archive: item.archive, length: item.length, size: asset.size)
    }
    if let publishedAt = release.publishedAt, AppcastWriter.date(publishedAt) == nil {
      throw AppcastError.invalidPublicationDate(tag: tag, publishedAt)
    }
    return .success(
      AppcastEntry(
        release: release, item: item, version: version, build: build,
        archiveURL: asset.browserDownloadURL))
  }
}

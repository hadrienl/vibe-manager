import Foundation

/// A release as the GitHub REST API describes it, reduced to what the feed reads.
public struct GitHubRelease: Decodable, Equatable, Sendable {
  public struct Asset: Decodable, Equatable, Sendable {
    public var name: String
    public var size: Int
    public var browserDownloadURL: String

    public init(name: String, size: Int, browserDownloadURL: String) {
      self.name = name
      self.size = size
      self.browserDownloadURL = browserDownloadURL
    }

    enum CodingKeys: String, CodingKey {
      case name, size
      case browserDownloadURL = "browser_download_url"
    }
  }

  public var tagName: String
  public var draft: Bool
  public var prerelease: Bool
  public var htmlURL: String
  /// `nil` while the release is a draft.
  public var publishedAt: String?
  public var body: String?
  public var assets: [Asset]

  public init(
    tagName: String, draft: Bool, prerelease: Bool, htmlURL: String, publishedAt: String?,
    body: String?, assets: [Asset]
  ) {
    self.tagName = tagName
    self.draft = draft
    self.prerelease = prerelease
    self.htmlURL = htmlURL
    self.publishedAt = publishedAt
    self.body = body
    self.assets = assets
  }

  enum CodingKeys: String, CodingKey {
    case draft, prerelease, body, assets
    case tagName = "tag_name"
    case htmlURL = "html_url"
    case publishedAt = "published_at"
  }

  /// Reads the output of `gh api --paginate --slurp …/releases`, an array of pages, or a plain
  /// array of releases.
  public static func decodeList(from data: Data) throws -> [GitHubRelease] {
    let decoder = JSONDecoder()
    if let pages = try? decoder.decode([[GitHubRelease]].self, from: data) {
      return pages.flatMap { $0 }
    }
    do {
      return try decoder.decode([GitHubRelease].self, from: data)
    } catch {
      throw AppcastError.malformedReleases(String(describing: error))
    }
  }
}

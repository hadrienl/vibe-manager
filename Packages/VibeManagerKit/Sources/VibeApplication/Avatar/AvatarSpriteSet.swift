import Foundation

/// What describes an avatar, beside its images: `manifest.json`, in its folder and in its archive.
public struct AvatarManifest: Codable, Hashable, Sendable {
  public enum Source: String, Codable, Hashable, Sendable {
    /// Shipped with the application.
    case bundled
    /// Drawn by an agent from a description.
    case generated
    /// Read from an archive.
    case imported
  }

  /// The version of the format this application writes. An archive of a later one is refused: it
  /// may mean something this version cannot show.
  public static let currentFormat = 1
  public static let maximumNameLength = 60

  public var format: Int
  public var name: String
  public var source: Source
  /// The agent that drew it, when one did: `codex`.
  public var provider: String?
  /// What the user described, kept to draw it again. Left out of an export on request.
  public var description: String?
  public var createdAt: Date?
  /// The expressions it holds, by name. Names this version does not know are kept as they are.
  public var expressions: [String]

  public init(
    format: Int = AvatarManifest.currentFormat, name: String, source: Source,
    provider: String? = nil, description: String? = nil, createdAt: Date? = nil,
    expressions: [String] = AvatarExpression.allCases.map(\.rawValue)
  ) {
    self.format = format
    self.name = name
    self.source = source
    self.provider = provider
    self.description = description
    self.createdAt = createdAt
    self.expressions = expressions
  }

  /// Only the format is required: a manifest written by hand, or by an older version, may say
  /// less.
  public init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    format = try container.decode(Int.self, forKey: .format)
    name = try container.decodeIfPresent(String.self, forKey: .name) ?? ""
    source = (try? container.decodeIfPresent(Source.self, forKey: .source)) ?? .imported
    provider = try? container.decodeIfPresent(String.self, forKey: .provider)
    description = try? container.decodeIfPresent(String.self, forKey: .description)
    createdAt = try? container.decodeIfPresent(Date.self, forKey: .createdAt)
    expressions = (try? container.decodeIfPresent([String].self, forKey: .expressions)) ?? []
  }
}

/// An avatar: one image per expression, each a 512 × 512 PNG with a transparent background, the
/// character framed the same way in all of them (#41).
///
/// It may be incomplete: an archive of an older version, or drawn by hand, can lack expressions.
/// Only a complete one is ever used.
public struct AvatarSpriteSet: Hashable, Sendable {
  /// The side of every sprite, in pixels.
  public static let spriteSide = 512

  public var manifest: AvatarManifest
  /// Each expression's PNG, as the application wrote it.
  public var sprites: [AvatarExpression: Data]
  /// The sheet it was cut from, when there was one: the reference an expression is drawn again
  /// from.
  public var sheet: Data?

  public init(manifest: AvatarManifest, sprites: [AvatarExpression: Data], sheet: Data? = nil) {
    self.manifest = manifest
    self.sprites = sprites
    self.sheet = sheet
  }

  /// The expressions it lacks, in the animation's order.
  public var missingExpressions: [AvatarExpression] {
    AvatarExpression.allCases.filter { sprites[$0] == nil }
  }

  public var isComplete: Bool { missingExpressions.isEmpty }
}

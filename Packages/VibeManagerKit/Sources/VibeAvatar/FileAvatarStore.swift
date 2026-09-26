import Foundation
import VibeApplication

/// The avatar in use, in `Avatar/` beside the session store (#41): its manifest and its
/// PNGs, in a folder only its owner reads. No folder: the default avatar.
///
/// A new avatar is written beside the old one and swapped in with a single rename, so that a
/// failure halfway leaves the previous avatar whole.
public actor FileAvatarStore: AvatarStore {
  private let directory: URL
  private let fileManager = FileManager.default

  public init(directory: URL) {
    self.directory = directory
  }

  public func load() async throws -> AvatarSpriteSet? {
    guard fileManager.fileExists(atPath: directory.path) else { return nil }
    let manifestURL = directory.appendingPathComponent(AvatarImageProcessor.manifestFileName)
    guard let manifestData = try? Data(contentsOf: manifestURL),
      let manifest = try? AvatarImageProcessor.manifest(from: manifestData)
    else { throw AvatarStoreError.unreadable }
    var sprites: [AvatarExpression: Data] = [:]
    for expression in AvatarExpression.allCases {
      let url = directory.appendingPathComponent(expression.fileName)
      guard let data = try? Data(contentsOf: url) else { continue }
      // What the application wrote, read back as it would read anything: a file changed behind
      // its back is not trusted more for being in its folder.
      guard let image = try? ImageCodec.decode(data),
        image.width == AvatarSpriteSet.spriteSide, image.height == AvatarSpriteSet.spriteSide
      else { throw AvatarStoreError.unreadable }
      sprites[expression] = data
    }
    let sheet = try? Data(
      contentsOf: directory.appendingPathComponent(AvatarImageProcessor.sheetFileName))
    let avatar = AvatarSpriteSet(manifest: manifest, sprites: sprites, sheet: sheet)
    guard avatar.isComplete else { throw AvatarStoreError.incomplete(avatar.missingExpressions) }
    return avatar
  }

  public func save(_ avatar: AvatarSpriteSet) async throws {
    let parent = directory.deletingLastPathComponent()
    try fileManager.createDirectory(
      at: parent, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    let staging = parent.appendingPathComponent(
      ".\(directory.lastPathComponent)-\(UUID().uuidString)", isDirectory: true)
    try fileManager.createDirectory(
      at: staging, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
    do {
      try AvatarImageProcessor.encode(avatar.manifest).write(
        to: staging.appendingPathComponent(AvatarImageProcessor.manifestFileName))
      for (expression, sprite) in avatar.sprites {
        try sprite.write(to: staging.appendingPathComponent(expression.fileName))
      }
      if let sheet = avatar.sheet {
        try sheet.write(to: staging.appendingPathComponent(AvatarImageProcessor.sheetFileName))
      }
      if fileManager.fileExists(atPath: directory.path) {
        _ = try fileManager.replaceItemAt(directory, withItemAt: staging)
      } else {
        try fileManager.moveItem(at: staging, to: directory)
      }
    } catch {
      try? fileManager.removeItem(at: staging)
      throw error
    }
  }

  public func remove() async throws {
    guard fileManager.fileExists(atPath: directory.path) else { return }
    try fileManager.removeItem(at: directory)
  }
}

/// The avatar shipped with the application: an archive in this module's resources, read by the
/// same code as any archive a user imports (#41).
public enum DefaultAvatar {
  /// The archive's name in the resources. Replacing the avatar is replacing this file.
  public static let resourceName = "DefaultAvatar"

  /// The default avatar. It is checked by the tests; should it ever fail to read, `nil` — and the
  /// panel shows its requests without an avatar rather than not at all.
  public static func load() -> AvatarSpriteSet? {
    guard let url = Bundle.module.url(forResource: resourceName, withExtension: "zip"),
      let data = try? Data(contentsOf: url),
      var avatar = try? AvatarImageProcessor().avatar(fromArchive: data).avatar,
      avatar.isComplete
    else { return nil }
    avatar.manifest.source = .bundled
    return avatar
  }
}

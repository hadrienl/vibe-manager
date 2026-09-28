import Foundation
import VibeApplication

/// The avatar shipped with the application: an archive in this module's resources, read by the
/// same code as any archive a user imports (#41).
public enum DefaultAvatar {
  /// The archive's name in the resources. Replacing the avatar is replacing this file.
  public static let resourceName = "DefaultAvatar"

  static var archiveURL: URL? {
    Bundle.module.url(forResource: resourceName, withExtension: "zip")
  }

  /// The default avatar. The archive is the application's own, already made of sprites: its
  /// images are checked by their headers, not processed again — that would cost seconds at every
  /// launch. The tests pass it through the whole import. Should it ever fail to read, `nil`, and
  /// the panel shows its requests without an avatar rather than not at all.
  public static func load() -> AvatarSpriteSet? {
    guard let url = archiveURL, let data = try? Data(contentsOf: url),
      let entries = try? ZipArchiveReader.entries(of: data)
    else { return nil }
    var manifest = AvatarManifest(name: "", source: .bundled)
    var sprites: [AvatarExpression: Data] = [:]
    for entry in entries {
      if entry.name == AvatarImageProcessor.manifestFileName,
        let read = try? AvatarImageProcessor.manifest(from: entry.contents)
      {
        manifest = read
      } else if let expression = AvatarImageProcessor.expression(named: entry.name),
        ImageCodec.isSprite(entry.contents)
      {
        sprites[expression] = entry.contents
      }
    }
    manifest.source = .bundled
    let avatar = AvatarSpriteSet(manifest: manifest, sprites: sprites)
    return avatar.isComplete ? avatar : nil
  }
}

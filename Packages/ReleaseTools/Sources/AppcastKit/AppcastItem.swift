import Foundation

/// What `Scripts/release.sh` knows about an update archive when it builds it, attached to the
/// release as `VibeManager-<version>.appcast.json`. The feed takes the signature from here: it
/// never downloads an archive, and holds no key.
public struct AppcastItem: Decodable, Equatable, Sendable {
  public var version: String
  /// `CFBundleVersion`: the number of commits of `main`.
  public var build: String
  /// The name of the `.zip` asset of the release.
  public var archive: String
  public var length: Int
  public var edSignature: String
  public var minimumSystemVersion: String
  /// The protocol of the terminal host this version speaks (ADR 0017).
  public var hostProtocol: Int

  public init(
    version: String, build: String, archive: String, length: Int, edSignature: String,
    minimumSystemVersion: String, hostProtocol: Int
  ) {
    self.version = version
    self.build = build
    self.archive = archive
    self.length = length
    self.edSignature = edSignature
    self.minimumSystemVersion = minimumSystemVersion
    self.hostProtocol = hostProtocol
  }

  /// Reads every `<tag>.json` of a directory, keyed by tag.
  public static func files(in directory: URL) throws -> [String: Data] {
    let names = try FileManager.default.contentsOfDirectory(atPath: directory.path)
    var files: [String: Data] = [:]
    for name in names where name.hasSuffix(".json") {
      let tag = String(name.dropLast(".json".count))
      files[tag] = try Data(contentsOf: directory.appendingPathComponent(name))
    }
    return files
  }
}

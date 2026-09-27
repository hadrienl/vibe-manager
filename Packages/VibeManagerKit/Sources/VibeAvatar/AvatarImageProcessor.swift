import Foundation
import VibeApplication
import VibePersistence

/// Images and archives of avatars, for `AvatarWorkshop` (#41).
public struct AvatarImageProcessor: AvatarImageProcessing {
  static let manifestFileName = "manifest.json"
  static let sheetFileName = "sheet.png"
  static let maximumManifestBytes = 64 * 1024
  /// The smallest side an image of an archive may have.
  static let minimumDrawingSide = 128
  /// The largest side an image of an archive may have: four times a sprite's.
  static let maximumDrawingSide = 2_048
  /// The largest side the sheet of an archive may have: a grid of drawings, kept only as a
  /// reference, and dropped rather than decoded when larger.
  static let maximumSheetSide = 4_096

  public init() {}

  public func sprites(fromSheet data: Data, expressions: [AvatarExpression]) throws
    -> [AvatarExpression: Data]
  {
    try SpriteSheetProcessor.sprites(fromSheet: data, expressions: expressions)
  }

  public func sprite(
    fromImage data: Data, as expression: AvatarExpression, matching reference: Data?
  ) throws -> Data {
    try SpriteSheetProcessor.sprite(fromImage: data, as: expression, matching: reference)
  }

  public func avatar(fromArchive data: Data) throws -> (avatar: AvatarSpriteSet, ignoredFiles: Int)
  {
    let entries = try ZipArchiveReader.entries(of: data)
    var manifest: AvatarManifest?
    var sheet: Data?
    var ignored = 0
    var drawings: [(AvatarExpression, Data)] = []
    for entry in entries {
      let lowered = entry.name.lowercased()
      if lowered == Self.manifestFileName {
        guard manifest == nil else { throw AvatarProblem.archiveUnsafeEntry(entry.name) }
        manifest = try Self.manifest(from: entry.contents)
      } else if lowered == Self.sheetFileName {
        guard sheet == nil else { throw AvatarProblem.archiveUnsafeEntry(entry.name) }
        // Kept only as the reference to draw from, and only if it reads as an image.
        sheet = (try? ImageCodec.decode(entry.contents, maximumSide: Self.maximumSheetSide))
          .flatMap { try? ImageCodec.png($0) }
      } else if let expression = Self.expression(named: entry.name) {
        // `neutral.png` and `Neutral.jpg` would be two images for one expression.
        guard !drawings.contains(where: { $0.0 == expression }) else {
          throw AvatarProblem.duplicateExpression(expression)
        }
        drawings.append((expression, entry.contents))
      } else {
        ignored += 1
      }
    }
    guard !drawings.isEmpty else { throw AvatarProblem.archiveHasNoImage }
    // One image decoded at a time, and none larger than an avatar needs: an archive of large
    // images is refused rather than held in memory all at once.
    var side: Int?
    var sprites: [AvatarExpression: Data] = [:]
    for (expression, contents) in drawings.sorted(by: { Self.order($0.0) < Self.order($1.0) }) {
      let image = try ImageCodec.decode(contents, maximumSide: Self.maximumDrawingSide)
      guard image.width == image.height else { throw AvatarProblem.imageNotSquare(expression) }
      guard image.width >= Self.minimumDrawingSide else {
        throw AvatarProblem.imageTooSmall(expression)
      }
      guard image.width == side ?? image.width else {
        throw AvatarProblem.imagesOfDifferentSizes(expression)
      }
      side = image.width
      sprites[expression] = try SpriteSheetProcessor.sprite(fromDrawing: image, as: expression)
    }
    var result = manifest ?? AvatarManifest(name: "", source: .imported)
    result.source = .imported
    // Shown through `DisplaySafeText`, like anything else that came from outside.
    result.name = String(result.name.prefix(AvatarManifest.maximumNameLength))
    result.expressions = AvatarExpression.allCases.filter { sprites[$0] != nil }.map(\.rawValue)
    return (AvatarSpriteSet(manifest: result, sprites: sprites, sheet: sheet), ignored)
  }

  public func archive(_ avatar: AvatarSpriteSet) throws -> Data {
    var files = [
      DiagnosticFile(name: Self.manifestFileName, contents: try Self.encode(avatar.manifest))
    ]
    for expression in AvatarExpression.allCases {
      guard let sprite = avatar.sprites[expression] else { continue }
      files.append(DiagnosticFile(name: expression.fileName, contents: sprite))
    }
    if let sheet = avatar.sheet {
      files.append(DiagnosticFile(name: Self.sheetFileName, contents: sheet))
    }
    return ZipArchiveWriter.archive(files)
  }

  // MARK: - Manifest

  static func manifest(from data: Data) throws -> AvatarManifest {
    guard data.count <= maximumManifestBytes,
      let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    else { throw AvatarProblem.archiveUnreadable }
    // The version is read before anything else: a later format may not decode as this one.
    guard let format = object["format"] as? Int else { throw AvatarProblem.archiveUnreadable }
    guard format <= AvatarManifest.currentFormat else {
      throw AvatarProblem.archiveFromNewerVersion
    }
    do {
      return try decoder.decode(AvatarManifest.self, from: data)
    } catch {
      throw AvatarProblem.archiveUnreadable
    }
  }

  static func encode(_ manifest: AvatarManifest) throws -> Data {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    encoder.dateEncodingStrategy = .iso8601
    return try encoder.encode(manifest)
  }

  static let decoder: JSONDecoder = {
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    return decoder
  }()

  /// `neutral.png`, `Neutral.PNG`, `neutral.jpg`: the expression a file is named after.
  static func expression(named name: String) -> AvatarExpression? {
    let url = URL(fileURLWithPath: name)
    guard ["png", "jpg", "jpeg"].contains(url.pathExtension.lowercased()) else { return nil }
    let base = url.deletingPathExtension().lastPathComponent.lowercased()
    return AvatarExpression.allCases.first { $0.rawValue.lowercased() == base }
  }

  static func order(_ expression: AvatarExpression) -> Int {
    AvatarExpression.allCases.firstIndex(of: expression) ?? 0
  }
}

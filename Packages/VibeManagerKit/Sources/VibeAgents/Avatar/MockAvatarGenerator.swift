import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers
import VibeApplication

/// Draws an avatar without any agent (#41): a sheet of round faces on the magenta background the
/// real generators are asked for, or one face when an expression is drawn again. What the
/// interface tests generate with.
///
/// `VIBE_MOCK_AVATAR=fail` makes every generation fail, `=grid` answers a sheet of the wrong grid.
public struct MockAvatarGenerator: AvatarGenerating {
  private let behaviour: String?

  public init(environment: [String: String] = ProcessInfo.processInfo.environment) {
    behaviour = environment["VIBE_MOCK_AVATAR"]
  }

  public func generate(_ request: AvatarGenerationRequest) async throws -> Data {
    if behaviour == "fail" { throw AvatarGenerationError.failed("mock") }
    let (columns, rows) =
      behaviour == "grid" ? (3, 3) : request.reference == nil ? (5, 2) : (1, 1)
    guard let data = Self.sheet(columns: columns, rows: rows) else {
      throw AvatarGenerationError.noImage
    }
    return data
  }

  static func sheet(columns: Int, rows: Int, cell: Int = 300) -> Data? {
    let width = columns * cell
    let height = rows * cell
    guard
      let context = CGContext(
        data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    else { return nil }
    context.setFillColor(CGColor(srgbRed: 1, green: 0, blue: 1, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    for index in 0..<(columns * rows) {
      let x = CGFloat(index % columns * cell)
      let y = CGFloat(height - (index / columns + 1) * cell)
      context.setFillColor(CGColor(srgbRed: 0.3, green: 0.8, blue: 0.4, alpha: 1))
      context.fillEllipse(in: CGRect(x: x + 60, y: y + 60, width: 180, height: 180))
      context.setFillColor(CGColor(srgbRed: 0.1, green: 0.1, blue: 0.1, alpha: 1))
      context.fillEllipse(in: CGRect(x: x + 110, y: y + 160, width: 20, height: 24))
      context.fillEllipse(in: CGRect(x: x + 170, y: y + 160, width: 20, height: 24))
      // A mouth that differs from cell to cell, so that the animation can be seen to move.
      let mouth = CGFloat(8 + index * 4)
      context.fillEllipse(in: CGRect(x: x + 130, y: y + 100, width: 40, height: mouth))
    }
    guard let image = context.makeImage() else { return nil }
    let data = NSMutableData()
    guard
      let destination = CGImageDestinationCreateWithData(
        data as CFMutableData, UTType.png.identifier as CFString, 1, nil)
    else { return nil }
    CGImageDestinationAddImage(destination, image, nil)
    return CGImageDestinationFinalize(destination) ? data as Data : nil
  }
}

extension MockAgentProvider: AvatarGeneratingProviding {
  public func avatarGenerator() -> any AvatarGenerating {
    MockAvatarGenerator(environment: environment)
  }
}

import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers
import VibeApplication

/// An image as 8-bit RGBA pixels, not premultiplied, in sRGB: what every step of the avatar's
/// processing reads and writes (#41).
struct RGBAImage: Sendable {
  let width: Int
  let height: Int
  /// `width × height × 4` bytes, row after row from the top.
  var pixels: [UInt8]

  init(width: Int, height: Int, pixels: [UInt8]) {
    self.width = width
    self.height = height
    self.pixels = pixels
  }

  /// A transparent image.
  init(width: Int, height: Int) {
    self.init(
      width: width, height: height, pixels: [UInt8](repeating: 0, count: width * height * 4))
  }

  @inline(__always) func offset(_ x: Int, _ y: Int) -> Int { (y * width + x) * 4 }

  @inline(__always) func alpha(_ x: Int, _ y: Int) -> UInt8 { pixels[offset(x, y) + 3] }

  /// The part of the image in `rect`, as an image of its own.
  func cropped(x: Int, y: Int, width: Int, height: Int) -> RGBAImage {
    var result = RGBAImage(width: width, height: height)
    for row in 0..<height {
      let source = offset(x, y + row)
      let target = result.offset(0, row)
      result.pixels.replaceSubrange(
        target..<(target + width * 4), with: pixels[source..<(source + width * 4)])
    }
    return result
  }
}

/// Decoding with bounds, and encoding: the only ways an image enters or leaves the processing.
enum ImageCodec {
  /// The largest file read as an image.
  static let maximumBytes = 25 * 1024 * 1024
  /// The largest side decoded: read from the file's header, before any pixel is.
  static let maximumSide = 8_192

  /// The pixels of a PNG or JPEG, never more than the bounds allow.
  static func decode(_ data: Data, maximumSide: Int = ImageCodec.maximumSide) throws -> RGBAImage {
    guard data.count <= maximumBytes else { throw AvatarProblem.imageTooLarge }
    let options = [kCGImageSourceShouldCache: false] as CFDictionary
    guard let source = CGImageSourceCreateWithData(data as CFData, options),
      let type = CGImageSourceGetType(source).map({ UTType($0 as String) }) ?? nil,
      type.conforms(to: .png) || type.conforms(to: .jpeg),
      let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, options) as? [CFString: Any],
      let width = properties[kCGImagePropertyPixelWidth] as? Int,
      let height = properties[kCGImagePropertyPixelHeight] as? Int
    else { throw AvatarProblem.unreadableImage }
    guard width > 0, height > 0 else { throw AvatarProblem.unreadableImage }
    guard width <= maximumSide, height <= maximumSide else {
      throw AvatarProblem.imageTooLarge
    }
    guard let image = CGImageSourceCreateImageAtIndex(source, 0, options) else {
      throw AvatarProblem.unreadableImage
    }
    return try pixels(of: image)
  }

  /// Whether `data` is a PNG of a sprite's size, read from its header alone.
  static func isSprite(_ data: Data) -> Bool {
    let options = [kCGImageSourceShouldCache: false] as CFDictionary
    guard let source = CGImageSourceCreateWithData(data as CFData, options),
      let type = CGImageSourceGetType(source).flatMap({ UTType($0 as String) }),
      type.conforms(to: .png),
      let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, options) as? [CFString: Any]
    else { return false }
    let side = AvatarSpriteSet.spriteSide
    return properties[kCGImagePropertyPixelWidth] as? Int == side
      && properties[kCGImagePropertyPixelHeight] as? Int == side
  }

  /// Draws `image` into RGBA, and takes the premultiplication back out.
  static func pixels(of image: CGImage) throws -> RGBAImage {
    let width = image.width
    let height = image.height
    var pixels = [UInt8](repeating: 0, count: width * height * 4)
    let drawn = pixels.withUnsafeMutableBytes { buffer -> Bool in
      guard
        let context = CGContext(
          data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8,
          bytesPerRow: width * 4, space: sRGB,
          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
      else { return false }
      context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
      return true
    }
    guard drawn else { throw AvatarProblem.unreadableImage }
    unpremultiply(&pixels)
    return RGBAImage(width: width, height: height, pixels: pixels)
  }

  /// The image as a `CGImage`, premultiplied again for drawing.
  static func cgImage(of image: RGBAImage) -> CGImage? {
    var premultiplied = image.pixels
    for index in stride(from: 0, to: premultiplied.count, by: 4) {
      let alpha = Int(premultiplied[index + 3])
      guard alpha < 255 else { continue }
      for channel in 0..<3 {
        let value = (Int(premultiplied[index + channel]) * alpha + 127) / 255
        premultiplied[index + channel] = UInt8(value)
      }
    }
    guard let provider = CGDataProvider(data: Data(premultiplied) as CFData) else { return nil }
    return CGImage(
      width: image.width, height: image.height, bitsPerComponent: 8, bitsPerPixel: 32,
      bytesPerRow: image.width * 4,
      space: sRGB,
      bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
      provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
  }

  /// A PNG written by the application: nothing of the original file — no metadata, no profile of
  /// its own — goes through.
  static func png(_ image: RGBAImage) throws -> Data {
    guard let cgImage = cgImage(of: image) else { throw AvatarProblem.unreadableImage }
    let data = NSMutableData()
    guard
      let destination = CGImageDestinationCreateWithData(
        data as CFMutableData, UTType.png.identifier as CFString, 1, nil)
    else { throw AvatarProblem.unreadableImage }
    CGImageDestinationAddImage(destination, cgImage, nil)
    guard CGImageDestinationFinalize(destination) else { throw AvatarProblem.unreadableImage }
    return data as Data
  }

  /// `image` scaled into a `side × side` square, `rect` of the source filling it. What lies
  /// outside the source is transparent.
  static func render(
    _ image: RGBAImage, from rect: CGRect, into side: Int
  ) throws -> RGBAImage {
    guard let source = cgImage(of: image) else { throw AvatarProblem.unreadableImage }
    var pixels = [UInt8](repeating: 0, count: side * side * 4)
    let drawn = pixels.withUnsafeMutableBytes { buffer -> Bool in
      guard
        let context = CGContext(
          data: buffer.baseAddress, width: side, height: side, bitsPerComponent: 8,
          bytesPerRow: side * 4, space: sRGB,
          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
      else { return false }
      context.interpolationQuality = .high
      let scale = CGFloat(side) / rect.width
      // Core Graphics counts rows from the bottom; `rect` counts them from the top.
      let origin = CGPoint(
        x: -rect.minX * scale,
        y: -(CGFloat(image.height) - rect.maxY) * scale)
      context.draw(
        source,
        in: CGRect(
          origin: origin,
          size: CGSize(width: CGFloat(image.width) * scale, height: CGFloat(image.height) * scale)))
      return true
    }
    guard drawn else { throw AvatarProblem.unreadableImage }
    unpremultiply(&pixels)
    return RGBAImage(width: side, height: side, pixels: pixels)
  }

  /// Takes the premultiplication a Core Graphics context applied back out.
  static func unpremultiply(_ pixels: inout [UInt8]) {
    for index in stride(from: 0, to: pixels.count, by: 4) {
      let alpha = Int(pixels[index + 3])
      guard alpha > 0, alpha < 255 else { continue }
      for channel in 0..<3 {
        let value = (Int(pixels[index + channel]) * 255 + alpha / 2) / alpha
        pixels[index + channel] = UInt8(min(255, value))
      }
    }
  }

  static let sRGB = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
}

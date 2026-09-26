import CoreGraphics
import CoreVideo
import Foundation
import Vision
import VibeApplication

/// Takes the flat background out of an image the generator drew (#41).
///
/// Generators do not reliably draw transparency, so they are asked for a flat magenta, which is
/// keyed out here. The colour is read from the image's own border rather than assumed: "pure
/// magenta" comes back as a magenta. Where the border is not flat — the generator did not follow
/// the instructions — the subject is separated by Vision instead.
enum BackgroundRemoval {
  /// Colours closer than this to the background are background.
  static let innerDistance = 60.0
  /// Colours farther than this are the subject; in between, a soft edge.
  static let outerDistance = 140.0
  /// The share of the border that must be close to its median colour for it to count as flat.
  static let flatBorderShare = 0.9
  /// A border already this transparent needs nothing removed.
  static let transparentBorderShare = 0.95

  /// `image` with its background transparent.
  static func removed(from image: RGBAImage) throws -> RGBAImage {
    if transparentShare(ofBorderOf: image) >= transparentBorderShare { return image }
    if let background = flatBorderColour(of: image) {
      return keyed(image, background: background)
    }
    return try separated(image)
  }

  /// The share of the outermost pixels that are transparent.
  static func transparentShare(ofBorderOf image: RGBAImage) -> Double {
    let border = borderPixels(of: image)
    guard !border.isEmpty else { return 0 }
    return Double(border.filter { image.pixels[$0 + 3] < 32 }.count) / Double(border.count)
  }

  /// The median colour of the border, if nearly all of the border is that colour.
  static func flatBorderColour(of image: RGBAImage) -> (Double, Double, Double)? {
    let border = borderPixels(of: image)
    guard !border.isEmpty else { return nil }
    func median(_ channel: Int) -> Double {
      let values = border.map { image.pixels[$0 + channel] }.sorted()
      return Double(values[values.count / 2])
    }
    let colour = (median(0), median(1), median(2))
    let close = border.filter { distance(image, at: $0, to: colour) < innerDistance }.count
    return Double(close) / Double(border.count) >= flatBorderShare ? colour : nil
  }

  /// Chroma keying: the background goes, the soft edge between it and the subject keeps a partial
  /// alpha, and the background's colour is taken back out of that edge so no magenta fringe stays.
  static func keyed(_ image: RGBAImage, background: (Double, Double, Double)) -> RGBAImage {
    var result = image
    let background = [background.0, background.1, background.2]
    for index in stride(from: 0, to: result.pixels.count, by: 4) {
      let d = distance(image, at: index, to: (background[0], background[1], background[2]))
      let alpha: Double
      if d <= innerDistance {
        alpha = 0
      } else if d >= outerDistance {
        alpha = 1
      } else {
        alpha = (d - innerDistance) / (outerDistance - innerDistance)
      }
      let original = Double(image.pixels[index + 3]) / 255
      result.pixels[index + 3] = UInt8((alpha * original * 255).rounded())
      if alpha == 0 {
        // No colour behind a transparent pixel: nothing of the background survives a rescale.
        for channel in 0..<3 { result.pixels[index + channel] = 0 }
        continue
      }
      guard alpha < 1 else { continue }
      // observed = alpha × subject + (1 − alpha) × background, solved for the subject.
      for channel in 0..<3 {
        let observed = Double(image.pixels[index + channel])
        let subject = (observed - (1 - alpha) * background[channel]) / alpha
        result.pixels[index + channel] = UInt8(min(255, max(0, subject.rounded())))
      }
    }
    return result
  }

  /// Vision's separation of the foreground, for a background that is not flat.
  static func separated(_ image: RGBAImage) throws -> RGBAImage {
    guard let cgImage = ImageCodec.cgImage(of: image) else { throw AvatarProblem.unreadableImage }
    let handler = VNImageRequestHandler(cgImage: cgImage)
    let request = VNGenerateForegroundInstanceMaskRequest()
    do {
      try handler.perform([request])
    } catch {
      throw AvatarProblem.backgroundNotRemoved(.neutral)
    }
    guard let observation = request.results?.first,
      let mask = try? observation.generateScaledMaskForImage(
        forInstances: observation.allInstances, from: handler)
    else { throw AvatarProblem.backgroundNotRemoved(.neutral) }
    CVPixelBufferLockBaseAddress(mask, .readOnly)
    defer { CVPixelBufferUnlockBaseAddress(mask, .readOnly) }
    guard let base = CVPixelBufferGetBaseAddress(mask),
      CVPixelBufferGetWidth(mask) == image.width, CVPixelBufferGetHeight(mask) == image.height
    else { throw AvatarProblem.backgroundNotRemoved(.neutral) }
    let bytesPerRow = CVPixelBufferGetBytesPerRow(mask)
    var result = image
    // A one-component 32-bit float mask, from 0 to 1.
    for y in 0..<image.height {
      let row = base.advanced(by: y * bytesPerRow).assumingMemoryBound(to: Float32.self)
      for x in 0..<image.width {
        let offset = image.offset(x, y) + 3
        let value = Double(max(0, min(1, row[x])))
        result.pixels[offset] = UInt8((Double(image.pixels[offset]) * value).rounded())
      }
    }
    return result
  }

  // MARK: - Helpers

  /// The byte offsets of the image's outermost ring of pixels.
  static func borderPixels(of image: RGBAImage) -> [Int] {
    guard image.width > 1, image.height > 1 else { return [] }
    var offsets: [Int] = []
    for x in 0..<image.width {
      offsets.append(image.offset(x, 0))
      offsets.append(image.offset(x, image.height - 1))
    }
    for y in 1..<(image.height - 1) {
      offsets.append(image.offset(0, y))
      offsets.append(image.offset(image.width - 1, y))
    }
    return offsets
  }

  static func distance(_ image: RGBAImage, at index: Int, to colour: (Double, Double, Double))
    -> Double
  {
    let r = Double(image.pixels[index]) - colour.0
    let g = Double(image.pixels[index + 1]) - colour.1
    let b = Double(image.pixels[index + 2]) - colour.2
    return (r * r + g * g + b * b).squareRoot()
  }
}

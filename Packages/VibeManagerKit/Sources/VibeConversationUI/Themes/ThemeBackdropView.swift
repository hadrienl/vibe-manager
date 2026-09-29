import AppKit
import CoreImage
import SwiftUI
import VibeApplication

/// What is behind a conversation: the theme's background colour, and its picture under a veil of
/// that colour, when it has one (#118). Decorative: VoiceOver never hears it.
struct ThemeBackdropView: View {
  let theme: ConversationTheme

  var body: some View {
    ZStack {
      theme.background.color
      if let url = theme.backdrop.localImage,
        let image = ThemeBackdropImages.image(at: url, blur: theme.backdrop.blur)
      {
        Image(nsImage: image)
          .resizable()
          .scaledToFill()
          .frame(maxWidth: .infinity, maxHeight: .infinity)
          .overlay(theme.background.color.opacity(theme.backdrop.veil))
      }
    }
    .clipped()
    .allowsHitTesting(false)
    .accessibilityHidden(true)
  }
}

/// The pictures of the themes, read once and blurred once: a view drawn again for every message
/// that arrives must not decode a photograph each time.
@MainActor
enum ThemeBackdropImages {
  private struct Key: Hashable {
    let url: URL
    let blur: Int
  }

  private static var images: [Key: NSImage] = [:]
  private static var order: [Key] = []
  /// A few pictures: the theme in force, the one on trial, and the cards of the grid.
  private static let capacity = 12
  /// The longest side a picture is blurred at: it is blurred anyway, and fills a window.
  private static let blurredSide: CGFloat = 1600

  static func image(at url: URL, blur: Double) -> NSImage? {
    let key = Key(url: url, blur: Int(blur.rounded()))
    if let image = images[key] { return image }
    guard let image = load(url, blur: CGFloat(key.blur)) else { return nil }
    images[key] = image
    order.append(key)
    if order.count > capacity { images[order.removeFirst()] = nil }
    return image
  }

  private static func load(_ url: URL, blur: CGFloat) -> NSImage? {
    guard let original = NSImage(contentsOf: url) else { return nil }
    guard blur > 0,
      let cgImage = original.cgImage(forProposedRect: nil, context: nil, hints: nil)
    else { return original }
    let scale = min(1, blurredSide / CGFloat(max(cgImage.width, cgImage.height)))
    var image = CIImage(cgImage: cgImage)
      .transformed(by: CGAffineTransform(scaleX: scale, y: scale))
    let extent = image.extent
    // Clamped first, so that the edges do not fade into transparency.
    image = image.clampedToExtent().applyingGaussianBlur(sigma: Double(blur * scale))
      .cropped(to: extent)
    let context = CIContext()
    guard let blurred = context.createCGImage(image, from: extent) else { return original }
    return NSImage(cgImage: blurred, size: NSSize(width: extent.width, height: extent.height))
  }
}

import AppKit
import SwiftUI
import Testing
import VibeApplication

@testable import VibeConversationUI

/// A picture fills the backdrop of a theme, and is cut to it: on a theme's card, it stays inside
/// the thumbnail instead of covering the name under it and the card around it (#224).
@MainActor
@Suite("The backdrop of a theme stays within its bounds (#224)")
struct ThemeBackdropBoundsTests {
  private static let cardWidth: CGFloat = 160
  /// The card's padding, then the thumbnail's height (`ThemeCard`).
  private static let padding: CGFloat = 6
  private static let thumbnailHeight: CGFloat = 56

  /// A plain red picture of that size, in a folder of its own.
  private func picture(width: Int, height: Int) throws -> URL {
    let context = try #require(
      CGContext(
        data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpace(name: CGColorSpace.sRGB)!,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
    context.setFillColor(red: 1, green: 0, blue: 0, alpha: 1)
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    let image = try #require(context.makeImage())
    let data = try #require(
      NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]))
    let url = FileManager.default.temporaryDirectory
      .appendingPathComponent("ThemeBackdropBounds-\(UUID().uuidString).png")
    try data.write(to: url)
    return url
  }

  /// The card of a theme whose picture is shown as it is, drawn off screen at one pixel a point.
  private func card(picture url: URL) throws -> NSBitmapImageRep {
    var theme = ConversationTheme.night
    theme.backdrop.localImage = url
    theme.backdrop.veil = 0
    theme.backdrop.blur = 0
    let renderer = ImageRenderer(
      content: ThemeCard(theme: theme, isCurrent: false, isOther: false)
        .frame(width: Self.cardWidth))
    renderer.scale = 1
    let image = try #require(renderer.cgImage)
    return NSBitmapImageRep(cgImage: image)
  }

  private func isRed(_ rep: NSBitmapImageRep, x: CGFloat, y: CGFloat) -> Bool {
    guard let color = rep.colorAt(x: Int(x), y: Int(y))?.usingColorSpace(.sRGB) else {
      return false
    }
    return color.alphaComponent > 0.9 && color.redComponent > 0.8 && color.greenComponent < 0.2
      && color.blueComponent < 0.2
  }

  @Test("A tall picture covers the thumbnail, not the name under it nor the card above it")
  func tallPicture() throws {
    let url = try picture(width: 40, height: 400)
    defer { try? FileManager.default.removeItem(at: url) }
    let rep = try card(picture: url)
    let middle = Self.cardWidth / 2
    #expect(isRed(rep, x: middle, y: Self.padding + Self.thumbnailHeight / 2))
    #expect(!isRed(rep, x: middle, y: Self.padding / 2), "above the thumbnail")
    #expect(!isRed(rep, x: middle, y: CGFloat(rep.pixelsHigh) - Self.padding / 2), "under the name")
  }

  @Test("A wide picture covers the thumbnail, not the card beside it")
  func widePicture() throws {
    let url = try picture(width: 400, height: 40)
    defer { try? FileManager.default.removeItem(at: url) }
    let rep = try card(picture: url)
    let row = Self.padding + Self.thumbnailHeight / 2
    #expect(isRed(rep, x: Self.cardWidth / 2, y: row))
    #expect(!isRed(rep, x: Self.padding / 2, y: row), "left of the thumbnail")
    #expect(!isRed(rep, x: Self.cardWidth - Self.padding / 2, y: row), "right of the thumbnail")
  }
}

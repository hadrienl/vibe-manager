import SwiftUI
import Testing

@testable import VibeUI

@Suite("The bubble of the floating requests")
struct BubbleShapeTests {
  private let rect = CGRect(x: 0, y: 0, width: 200, height: 120)

  private func moves(in path: Path) -> Int {
    var count = 0
    path.forEach { if case .move = $0 { count += 1 } }
    return count
  }

  @Test(
    "draws its tail as part of its single outline",
    arguments: [(true, true), (true, false), (false, true), (false, false)])
  func singleOutline(tailLeading: Bool, tailBottom: Bool) {
    let shape = BubbleShape(tailLeading: tailLeading, tailBottom: tailBottom)
    for path in [shape.path(in: rect), shape.inset(by: 0.5).path(in: rect)] {
      #expect(moves(in: path) == 1)
    }
    let bounds = shape.path(in: rect).boundingRect
    #expect(tailLeading ? bounds.minX == rect.minX - 8 : bounds.minX == rect.minX)
    #expect(tailLeading ? bounds.maxX == rect.maxX : bounds.maxX == rect.maxX + 8)
    #expect(bounds.minY == rect.minY)
    #expect(bounds.maxY == rect.maxY)
  }

  @Test("keeps its tail on the side, clear of the corners, in a short bubble")
  func shortBubble() {
    let short = CGRect(x: 0, y: 0, width: 200, height: 40)
    let tip = BubbleShape(tailLeading: true, tailBottom: true).path(in: short)
      .boundingRect
    #expect(tip.minX == -8)
    #expect(tip.minY == 0)
    #expect(tip.maxY == 40)
  }
}

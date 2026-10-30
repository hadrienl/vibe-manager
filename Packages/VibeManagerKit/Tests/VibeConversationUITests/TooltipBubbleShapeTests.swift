import AppKit
import SwiftUI
import Testing

@testable import VibeConversationUI

@Suite("The tooltip's bubble")
struct TooltipBubbleShapeTests {
  @Test("The arrow is part of the bubble's one outline, its tip at the bottom over the view")
  func oneOutline() {
    let rect = CGRect(x: 0, y: 0, width: 250, height: 60)
    let path = TooltipBubbleShape(arrowX: 125).path(in: rect)
    var starts = 0
    path.forEach { if case .move = $0 { starts += 1 } }
    #expect(starts == 1)
    #expect(path.boundingRect.maxY == rect.maxY)
    #expect(path.contains(CGPoint(x: 125, y: rect.maxY - 1)))
    #expect(!path.contains(CGPoint(x: 20, y: rect.maxY - 1)))
  }

  @Test("Near the window's edge, the arrow stays clear of the bubble's corner")
  func arrowClearOfCorner() {
    let rect = CGRect(x: 0, y: 0, width: 250, height: 60)
    let path = TooltipBubbleShape(arrowX: 0).path(in: rect)
    #expect(!path.contains(CGPoint(x: 1, y: rect.maxY - 1)))
    #expect(path.contains(CGPoint(x: 15, y: rect.maxY - 1)))
  }

  @Test("Pointing up, the arrow's tip is at the top")
  func pointsUp() {
    let rect = CGRect(x: 0, y: 0, width: 250, height: 60)
    let path = TooltipBubbleShape(arrowX: 125, pointsDown: false).path(in: rect)
    #expect(path.boundingRect.minY == rect.minY)
    #expect(path.contains(CGPoint(x: 125, y: rect.minY + 1)))
    #expect(!path.contains(CGPoint(x: 20, y: rect.minY + 1)))
  }

  @Test("On a side, the arrow's tip is on that side, at its height")
  func pointsSideways() {
    let rect = CGRect(x: 0, y: 0, width: 250, height: 40)
    let left = TooltipBubbleShape(arrowX: 20, arrowEdge: .left).path(in: rect)
    #expect(left.boundingRect.minX == rect.minX)
    #expect(left.contains(CGPoint(x: rect.minX + 1, y: 20)))
    #expect(!left.contains(CGPoint(x: rect.minX + 1, y: 2)))
    let right = TooltipBubbleShape(arrowX: 20, arrowEdge: .right).path(in: rect)
    #expect(right.boundingRect.maxX == rect.maxX)
    #expect(right.contains(CGPoint(x: rect.maxX - 1, y: 20)))
  }
}

/// Where the bubble stands on screen, its origin at the bottom as AppKit's.
@Suite("Where the tooltip stands")
struct TooltipPlacementTests {
  private let screen = CGRect(x: 0, y: 0, width: 1440, height: 875)
  private let window = CGRect(x: 100, y: 100, width: 800, height: 600)
  private let size = CGSize(width: 200, height: 40)

  @Test("Above the view, its arrow's tip just over it, centred on it")
  func aboveAndCentred() {
    let anchor = CGRect(x: 400, y: 300, width: 80, height: 20)
    let placement = TooltipPlacement(size: size, anchor: anchor, window: window, screen: screen)
    #expect(placement.pointsDown)
    #expect(placement.frame.minY == anchor.maxY + TooltipPlacement.gap)
    #expect(placement.frame.midX == anchor.midX)
    #expect(placement.arrowX == size.width / 2)
  }

  @Test("Near the window's sides, the bubble keeps in it, its arrow still over the view")
  func keepsInTheWindow() {
    let leading = CGRect(x: 104, y: 300, width: 30, height: 20)
    let left = TooltipPlacement(size: size, anchor: leading, window: window, screen: screen)
    #expect(left.frame.minX == window.minX + TooltipPlacement.margin)
    #expect(left.frame.minX + left.arrowX == leading.midX)

    let trailing = CGRect(x: 870, y: 300, width: 30, height: 20)
    let right = TooltipPlacement(size: size, anchor: trailing, window: window, screen: screen)
    #expect(right.frame.maxX == window.maxX - TooltipPlacement.margin)
    #expect(right.frame.minX + right.arrowX == trailing.midX)
  }

  @Test("At the top of the screen, the bubble goes under the view, its arrow up")
  func underAtTheTop() {
    let anchor = CGRect(x: 400, y: 850, width: 80, height: 20)
    let placement = TooltipPlacement(size: size, anchor: anchor, window: window, screen: screen)
    #expect(!placement.pointsDown)
    #expect(placement.frame.maxY == anchor.minY - TooltipPlacement.gap)
  }

  @Test("On a side, the bubble opens beside the view, centred on it, its arrow towards it (#458)")
  func beside() {
    let anchor = CGRect(x: 400, y: 300, width: 40, height: 14)
    let right = TooltipPlacement(
      size: size, anchor: anchor, window: window, screen: screen, edge: .right)
    #expect(right.frame.minX == anchor.maxX + TooltipPlacement.gap)
    #expect(right.frame.midY == anchor.midY)
    #expect(right.arrowEdge == .left)
    #expect(right.frame.maxY - right.arrowX == anchor.midY)

    let left = TooltipPlacement(
      size: size, anchor: anchor, window: window, screen: screen, edge: .left)
    #expect(left.frame.maxX == anchor.minX - TooltipPlacement.gap)
    #expect(left.arrowEdge == .right)
  }

  @Test("Without room on its side, the bubble opens on the other, whole in the window (#458)")
  func besideFlips() {
    let atTheRight = CGRect(x: 840, y: 300, width: 40, height: 14)
    let placement = TooltipPlacement(
      size: size, anchor: atTheRight, window: window, screen: screen, edge: .right)
    #expect(placement.frame.maxX == atTheRight.minX - TooltipPlacement.gap)
    #expect(placement.arrowEdge == .right)
    #expect(window.contains(placement.frame))

    let atTheBottom = CGRect(x: 400, y: 102, width: 40, height: 14)
    let low = TooltipPlacement(
      size: size, anchor: atTheBottom, window: window, screen: screen, edge: .left)
    #expect(low.frame.minY == window.minY + TooltipPlacement.margin)
    #expect(window.contains(low.frame))
  }

  @Test("Pushed along the view by the window, the side arrow stays clear of the corners")
  func sideArrowClearOfCorners() {
    let atTheBottom = CGRect(x: 400, y: 96, width: 40, height: 8)
    let low = TooltipPlacement(
      size: size, anchor: atTheBottom, window: window, screen: screen, edge: .right)
    #expect(low.frame.minY == window.minY + TooltipPlacement.margin)
    #expect(low.arrowX == size.height - TooltipBubbleShape.arrowClearance)

    let atTheTop = CGRect(x: 400, y: 696, width: 40, height: 8)
    let high = TooltipPlacement(
      size: size, anchor: atTheTop, window: window, screen: screen, edge: .right)
    #expect(high.arrowX == TooltipBubbleShape.arrowClearance)
  }

  @Test("Leading and trailing follow the layout's direction")
  func sidesInTheDirection() {
    #expect(TooltipSide.leading.edge(in: .leftToRight) == .left)
    #expect(TooltipSide.trailing.edge(in: .leftToRight) == .right)
    #expect(TooltipSide.leading.edge(in: .rightToLeft) == .right)
    #expect(TooltipSide.trailing.edge(in: .rightToLeft) == .left)
  }
}

/// The bubble measured for its text, in a hosting controller never put in a window.
@MainActor
@Suite("The tooltip's size")
struct TooltipSizeTests {
  private func size(of text: String) -> CGSize {
    TooltipBubble.size(of: Text(verbatim: text))
  }

  @Test("As wide as a short text; a long one wraps at the widest")
  func fitsItsText() {
    let short = size(of: "Back")
    let long = size(of: String(repeating: "The agent can create sessions of its own. ", count: 4))
    #expect(short.width < 100)
    #expect(short.width >= 2 * TooltipBubbleShape.arrowClearance)
    #expect(long.width <= TooltipBubble.maximumWidth)
    #expect(long.width > TooltipBubble.maximumWidth - 30)
    #expect(long.height > 2 * short.height)
  }
}

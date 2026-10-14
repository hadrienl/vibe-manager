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
}

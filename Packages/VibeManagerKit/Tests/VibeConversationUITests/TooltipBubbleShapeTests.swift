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
}

/// The bubble laid out in a window never put on screen, next to the view it explains.
@MainActor
@Suite("Where the tooltip stands", .serialized, .timeLimit(.minutes(1)))
struct TooltipPlacementTests {
  private final class Frames {
    var bubble: CGRect?
    var anchor: CGRect?
  }

  private func measure(anchorX: CGFloat) async throws -> Frames {
    let frames = Frames()
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 500, height: 300),
      styleMask: [.titled], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.contentView = NSHostingView(
      rootView: ZStack(alignment: .bottomLeading) {
        Color.clear
        Text(verbatim: "Coordinate")
          .padding(4)
          .instantTooltip(
            Text(verbatim: "The agent can create sessions of its own."), isShown: true
          )
          .onGeometryChange(for: CGRect.self) {
            $0.frame(in: .global)
          } action: {
            frames.anchor = $0
          }
          .padding(.leading, anchorX)
          .padding(.bottom, 20)
      }
      .onPreferenceChange(TooltipBubbleFrameKey.self) { frames.bubble = $0 }
      .frame(width: 500, height: 300))
    while frames.bubble == nil || frames.anchor == nil {
      try Task.checkCancellation()
      window.layoutIfNeeded()
      try await Task.sleep(for: .milliseconds(10))
    }
    return frames
  }

  @Test("Above the view, its arrow's tip just over it, centred on it")
  func aboveAndCentred() async throws {
    let frames = try await measure(anchorX: 200)
    let bubble = try #require(frames.bubble)
    let anchor = try #require(frames.anchor)
    #expect(bubble.maxY <= anchor.minY)
    #expect(anchor.minY - bubble.maxY < 6)
    #expect(abs(bubble.midX - anchor.midX) < 1)
  }

  @Test("Near the window's leading edge, the bubble keeps in it")
  func keepsInTheWindow() async throws {
    let frames = try await measure(anchorX: 4)
    let bubble = try #require(frames.bubble)
    let anchor = try #require(frames.anchor)
    #expect(bubble.minX >= TooltipBubble.margin - 1)
    #expect(bubble.maxY <= anchor.minY)
  }
}

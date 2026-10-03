import AppKit
import SwiftUI

/// Pages the conversation from the keyboard (#227). SwiftUI scrolls to an identifier only: a page
/// is asked of the `NSScrollView` the messages sit in, found from inside it.
@MainActor
final class ConversationPager {
  weak var scrollView: NSScrollView?

  func scroll(_ page: ConversationModel.Page) {
    guard let scrollView, let document = scrollView.documentView else { return }
    let clip = scrollView.contentView
    let y = Self.origin(
      after: page, from: clip.bounds.origin.y, visibleHeight: clip.bounds.height,
      documentHeight: document.frame.height, overlap: scrollView.verticalPageScroll,
      isFlipped: document.isFlipped)
    clip.scroll(to: NSPoint(x: clip.bounds.origin.x, y: y))
    scrollView.reflectScrolledClipView(clip)
  }

  /// Where the visible part starts after a page: one height of the view, less the part kept on
  /// screen to read on from, never past either end. A flipped document grows downwards.
  nonisolated static func origin(
    after page: ConversationModel.Page, from y: Double, visibleHeight: Double,
    documentHeight: Double, overlap: Double, isFlipped: Bool
  ) -> Double {
    let step = max(visibleHeight - overlap, visibleHeight / 2)
    let downwards = page == .down ? step : -step
    let next = y + (isFlipped ? downwards : -downwards)
    return min(max(next, 0), max(documentHeight - visibleHeight, 0))
  }
}

/// Hands the pager the scroll view it is placed in.
struct ConversationPagerProbe: NSViewRepresentable {
  let pager: ConversationPager

  func makeNSView(context: Context) -> Probe {
    let probe = Probe()
    probe.pager = pager
    return probe
  }

  func updateNSView(_ probe: Probe, context: Context) {
    probe.pager = pager
    probe.attach()
  }

  final class Probe: NSView {
    weak var pager: ConversationPager?

    override func viewDidMoveToWindow() {
      super.viewDidMoveToWindow()
      attach()
    }

    func attach() {
      if let scrollView = enclosingScrollView { pager?.scrollView = scrollView }
    }
  }
}

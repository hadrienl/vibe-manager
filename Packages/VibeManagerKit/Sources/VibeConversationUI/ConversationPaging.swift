import AppKit
import SwiftUI

/// Pages the conversation from the keyboard (#227). SwiftUI scrolls to an identifier only: a page
/// is asked of the `NSScrollView` the messages sit in, found from inside it, as a scroll of the
/// wheel — SwiftUI follows that one, and puts back a position set on the clip view behind it.
@MainActor
final class ConversationPager {
  weak var scrollView: NSScrollView?

  func scroll(_ page: ConversationModel.Page) {
    guard let scrollView, let document = scrollView.documentView else { return }
    let clip = scrollView.contentView
    let insets = scrollView.contentInsets
    let y = Self.origin(
      after: page, from: clip.bounds.origin.y, viewHeight: clip.bounds.height,
      documentHeight: document.frame.height, insets: (top: insets.top, bottom: insets.bottom),
      overlap: scrollView.verticalPageScroll, isFlipped: document.isFlipped)
    // As the wheel does: SwiftUI keeps the position it knows, and takes back one set behind it.
    let distance = (y - clip.bounds.origin.y) * (document.isFlipped ? 1 : -1)
    if let event = CGEvent(
      scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1,
      wheel1: Int32(-distance.rounded()), wheel2: 0, wheel3: 0),
      let wheel = NSEvent(cgEvent: event)
    {
      scrollView.scrollWheel(with: wheel)
    }
  }

  /// Where the view starts after a page. The messages scroll under the toolbar, which veils them
  /// (#118, #228): only what lies between the insets is read, so a page is that height, less the
  /// part kept on screen to read on from — no line is skipped under the veil — and the ends are
  /// those of the insets, the first message below the toolbar. A flipped document grows downwards.
  nonisolated static func origin(
    after page: ConversationModel.Page, from y: Double, viewHeight: Double,
    documentHeight: Double, insets: (top: Double, bottom: Double), overlap: Double,
    isFlipped: Bool
  ) -> Double {
    let readable = viewHeight - insets.top - insets.bottom
    let step = max(readable - overlap, readable / 2)
    let downwards = page == .down ? step : -step
    let next = y + (isFlipped ? downwards : -downwards)
    // The smallest origin shows the document's lowest coordinates: its top when it is flipped.
    let lowInset = isFlipped ? insets.top : insets.bottom
    let highInset = isFlipped ? insets.bottom : insets.top
    let lowest = -lowInset
    let highest = max(documentHeight - viewHeight + highInset, lowest)
    return min(max(next, lowest), highest)
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

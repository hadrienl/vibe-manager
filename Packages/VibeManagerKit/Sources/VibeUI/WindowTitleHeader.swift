import AppKit
import SwiftUI

/// The window's title as the toolbar draws it (#159): "Vibe Manager" in the secondary style, the
/// session on screen in the primary one, on one line.
///
/// It stands in for the title the system draws, which says it all in one style: the window keeps
/// that title — the Window menu, Mission Control and ⌘` read it — and only its drawing is removed.
/// Before macOS 15 it cannot be removed, and the system's title is the header.
struct WindowTitleToolbarItem: ToolbarContent {
  let title: WindowTitle
  let room: WindowTitleRoom

  /// Whether the header is drawn here rather than by the system.
  static var isDrawn: Bool {
    if #available(macOS 15, *) { return true }
    return false
  }

  var body: some ToolbarContent {
    // Where the system draws its own title: at the leading edge, not over the pickers in the
    // middle of the toolbar.
    if #available(macOS 26, *) {
      // Text, not a button: no capsule of glass around it.
      item.sharedBackgroundVisibility(.hidden)
    } else {
      item
    }
  }

  private var item: some ToolbarContent {
    ToolbarItem(placement: .navigation) {
      WindowTitleHeader(title: title, room: room)
    }
  }
}

extension View {
  /// Removes the title the system draws in the toolbar, when `WindowTitleToolbarItem` draws it.
  /// The window's title stays: the Window menu, Mission Control and ⌘` still read it.
  @ViewBuilder
  func removingSystemDrawnTitle() -> some View {
    if #available(macOS 15, *) {
      toolbar(removing: .title)
    } else {
      self
    }
  }
}

/// Where the detail column starts in the window. The toolbar centres its principal items — the
/// pickers of #69 and #38 — over what lies right of the sidebar, so the room left of them depends
/// on it. Only the header reads it: the whole window is not redrawn at each step of a drag.
@MainActor @Observable
final class WindowTitleRoom {
  var detailLeading: CGFloat = 0
}

struct WindowTitleHeader: View {
  let title: WindowTitle
  let room: WindowTitleRoom
  /// The width the toolbar can give, once measured.
  @State private var width: CGFloat?
  @State private var applicationWidth: CGFloat = 0

  /// Before the first measurement: little enough never to push another item out.
  private static let unmeasuredWidth: CGFloat = 80
  /// Below this much room for the session's name, the application's name gives way to it.
  private static let minimumNameWidth: CGFloat = 80

  var body: some View {
    let width = width ?? Self.unmeasuredWidth
    Group {
      if let sessionName = title.sessionName {
        HStack(spacing: 0) {
          if width >= applicationWidth + Self.minimumNameWidth {
            applicationAndSeparator
          }
          Text(verbatim: sessionName)
            .foregroundStyle(.primary)
            .truncationMode(.tail)
        }
      } else {
        Text(verbatim: title.applicationName)
          .foregroundStyle(.primary)
      }
    }
    .font(.headline)
    .lineLimit(1)
    .frame(maxWidth: width, alignment: .leading)
    // Measured apart, whether shown or not: whether it is shown depends on it.
    .background {
      applicationAndSeparator
        .hidden()
        .onGeometryChange(for: CGFloat.self) {
          $0.size.width
        } action: {
          applicationWidth = $0
        }
    }
    .background(
      ToolbarRoomReader(detailLeading: room.detailLeading) { measured in
        if self.width.map({ abs($0 - measured) >= 1 }) ?? true { self.width = measured }
      }
    )
    // The whole name, truncated or not: knowing whether it is would take a measurement for
    // nothing.
    .help(title.full)
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(title.spoken)
    .accessibilityAddTraits(.isHeader)
  }

  private var applicationAndSeparator: some View {
    HStack(spacing: 0) {
      Text(verbatim: title.applicationName)
        .foregroundStyle(.secondary)
      Text(verbatim: " › ")
        .foregroundStyle(.tertiary)
    }
    .font(.headline)
    .fixedSize()
  }
}

/// The room the toolbar leaves the title without sending another item to its overflow menu.
///
/// `NSToolbar` gives an item the width it asks for, never less: a title as wide as its text pushed
/// the buttons into the » menu instead of being truncated, and so did the system's own title. So
/// the header asks for no more than what is left once the other items have theirs.
struct ToolbarTitleLayout {
  /// Between two items, as `NSToolbar` spaces them, with a little to spare.
  static let spacing: CGFloat = 12
  /// Between the last item and the window's edge.
  static let trailingInset: CGFloat = 16

  /// - Parameters:
  ///   - titleLeading: where the title starts, after the traffic lights and the items before it.
  ///   - centredWidth: the width of the item centred in the toolbar, if there is one.
  ///   - trailingWidths: the widths of the items after the title, the centred one excepted.
  static func room(
    titleLeading: CGFloat, windowWidth: CGFloat, detailLeading: CGFloat, centredWidth: CGFloat?,
    trailingWidths: [CGFloat]
  ) -> CGFloat {
    let trailing = trailingWidths.reduce(trailingInset) { $0 + $1 + spacing }
    var bound = windowWidth - trailing
    if let centredWidth {
      // Centred right of the sidebar, unless the items after it push it back.
      let centred = (detailLeading + windowWidth) / 2 - centredWidth / 2
      bound = min(centred, bound - centredWidth)
    }
    return max(0, bound - spacing - titleLeading).rounded(.down)
  }
}

/// Measures, from inside the title's toolbar item, the room `ToolbarTitleLayout` gives it: again
/// when the window is resized, when an item comes or goes, and when one moves or changes width.
private struct ToolbarRoomReader: NSViewRepresentable {
  let detailLeading: CGFloat
  let measured: (CGFloat) -> Void

  func makeNSView(context: Context) -> ToolbarRoomView {
    ToolbarRoomView()
  }

  func updateNSView(_ view: ToolbarRoomView, context: Context) {
    view.detailLeading = detailLeading
    view.measured = measured
    view.scheduleMeasurement()
  }
}

final class ToolbarRoomView: NSView {
  var detailLeading: CGFloat = 0
  var measured: ((CGFloat) -> Void)?
  private var observers = NotificationObservers()
  private var observedItemViews: Set<ObjectIdentifier> = []
  /// The window last drawn in. Sent to the overflow menu, the title leaves the window, and must
  /// still see it grow to come back.
  private weak var hostWindow: NSWindow?
  private var isMeasurementScheduled = false
  /// Where the title starts, as last seen while it was on the bar.
  private var titleLeading: CGFloat?
  /// The width of each item as last seen on the bar: an item sent to the overflow menu is laid out
  /// there, and its width then says nothing of what it takes on the bar.
  private var widths: [NSToolbarItem.Identifier: CGFloat] = [:]

  override func viewDidMoveToWindow() {
    super.viewDidMoveToWindow()
    defer { scheduleMeasurement() }
    // Out of its window, into the overflow menu or on its way out: the window it was in is still
    // the one to watch.
    guard let window, window !== hostWindow else { return }
    hostWindow = window
    observers = NotificationObservers()
    observedItemViews = []
    observers.observe(NSWindow.didResizeNotification, of: window) { [weak self] in
      self?.scheduleMeasurement()
    }
    for name in [NSToolbar.willAddItemNotification, NSToolbar.didRemoveItemNotification] {
      observers.observe(name, of: window.toolbar) { [weak self] in self?.scheduleMeasurement() }
    }
  }

  /// On the next turn of the run loop: the toolbar is laid out by then, and several changes in a
  /// row are measured once.
  func scheduleMeasurement() {
    guard !isMeasurementScheduled else { return }
    isMeasurementScheduled = true
    DispatchQueue.main.async { [weak self] in
      guard let self else { return }
      isMeasurementScheduled = false
      measure()
    }
  }

  private func measure() {
    guard let window = hostWindow, let toolbar = window.toolbar,
      let ownIndex = toolbar.items.firstIndex(where: { item in
        item.view.map { isDescendant(of: $0) } ?? false
      })
    else { return }
    let visible = Set((toolbar.visibleItems ?? []).map(\.itemIdentifier))
    let own = toolbar.items[ownIndex]
    if let view = own.view, visible.contains(own.itemIdentifier) {
      let frame = view.convert(view.bounds, to: nil)
      if frame.width > 0 { titleLeading = frame.minX }
    }
    guard let titleLeading else { return }

    var centredWidth: CGFloat?
    var trailingWidths: [CGFloat] = []
    for (index, item) in toolbar.items.enumerated() where index != ownIndex {
      guard let view = item.view else { continue }
      observeFrame(of: view)
      if visible.contains(item.itemIdentifier) {
        widths[item.itemIdentifier] = view.fittingSize.width
      }
      let width = widths[item.itemIdentifier] ?? view.fittingSize.width
      if toolbar.centeredItemIdentifiers.contains(item.itemIdentifier) {
        centredWidth = width
      } else if index > ownIndex {
        trailingWidths.append(width)
      }
    }
    if let view = own.view { observeFrame(of: view) }
    measured?(
      ToolbarTitleLayout.room(
        titleLeading: titleLeading, windowWidth: window.frame.width,
        detailLeading: detailLeading, centredWidth: centredWidth, trailingWidths: trailingWidths))
  }

  /// An item that moves or changes width — the task status menu's label, the title's own place
  /// once the sidebar folds — changes the room too.
  private func observeFrame(of view: NSView) {
    guard observedItemViews.insert(ObjectIdentifier(view)).inserted else { return }
    view.postsFrameChangedNotifications = true
    observers.observe(NSView.frameDidChangeNotification, of: view) { [weak self] in
      self?.scheduleMeasurement()
    }
  }
}

/// Notification observers, removed with their holder.
private final class NotificationObservers: @unchecked Sendable {
  private var tokens: [NSObjectProtocol] = []

  @MainActor
  func observe(
    _ name: Notification.Name, of object: AnyObject?, _ action: @escaping @MainActor () -> Void
  ) {
    tokens.append(
      NotificationCenter.default.addObserver(forName: name, object: object, queue: .main) { _ in
        MainActor.assumeIsolated { action() }
      })
  }

  deinit {
    for token in tokens { NotificationCenter.default.removeObserver(token) }
  }
}

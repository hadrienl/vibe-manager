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
  /// All the width the toolbar can give, once measured: taken whole, it holds the buttons after it
  /// against the window's edge, as the system's title did.
  @State private var width: CGFloat?
  @State private var applicationWidth: CGFloat = 0

  /// Below this much room for the session's name, the application's name gives way to it.
  private static let minimumNameWidth: CGFloat = 80

  var body: some View {
    let width = width ?? ToolbarTitleLayout.unmeasuredWidth
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
    .frame(width: width, alignment: .leading)
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
    .modifier(MovesWindow())
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

/// The room the toolbar leaves the title.
///
/// `NSToolbar` gives an item the width it asks for, never less: a title as wide as its text pushed
/// the buttons into the » menu instead of being truncated, and so did the system's own title. And
/// with the system's title removed, nothing held the buttons against the window's right edge any
/// more: they followed the title. So the header takes exactly what is left once the other items
/// have theirs — no more, and no less.
struct ToolbarTitleLayout {
  /// Between two items, as `NSToolbar` spaces them.
  static let spacing: CGFloat = 8
  /// Between the last item and the window's edge.
  static let trailingInset: CGFloat = 8
  /// Before the first measurement, or sent to the » menu: little enough to find a place on the bar.
  static let unmeasuredWidth: CGFloat = 80

  /// - Parameters:
  ///   - titleLeading: where the title starts, after the traffic lights and the items before it.
  ///   - centredWidth: the width of the item centred in the toolbar, if there is one.
  ///   - trailingExtent: from the first item after the title to the last, the centred one
  ///     excepted; 0 when there is none.
  static func room(
    titleLeading: CGFloat, windowWidth: CGFloat, detailLeading: CGFloat, centredWidth: CGFloat?,
    trailingExtent: CGFloat
  ) -> CGFloat {
    let trailing = trailingExtent > 0 ? trailingInset + trailingExtent + spacing : trailingInset
    var bound = windowWidth - trailing
    if let centredWidth {
      // Centred right of the sidebar, unless the items after it push it back.
      let centred = (detailLeading + windowWidth) / 2 - centredWidth / 2
      bound = min(centred, bound - centredWidth) - spacing
    }
    return max(0, bound - titleLeading).rounded(.down)
  }

  /// What the items after the title take, when they could not be seen side by side: their widths
  /// and the spaces between them.
  static func estimatedExtent(of widths: [CGFloat]) -> CGFloat {
    widths.isEmpty ? 0 : widths.reduce(0, +) + spacing * CGFloat(widths.count - 1)
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
  /// The width of each item as last seen on the bar: an item sent to the overflow menu is laid out
  /// there, and its width then says nothing of what it takes on the bar.
  private var widths: [NSToolbarItem.Identifier: CGFloat] = [:]
  /// From the first item after the title to the last, as last seen all on the bar, for that set of
  /// items: the buttons grouped under one capsule sit closer than two items apart.
  private var trailingExtents: [[NSToolbarItem.Identifier]: CGFloat] = [:]

  override func viewDidMoveToWindow() {
    super.viewDidMoveToWindow()
    defer { scheduleMeasurement() }
    // Out of its window, into the overflow menu or on its way out: the window it was in is still
    // the one to watch.
    guard let window, window !== hostWindow else { return }
    hostWindow = window
    observers = NotificationObservers()
    observedItemViews = []
    // At once, not on the next turn: a window made narrower would otherwise be drawn once with
    // its last button in the » menu.
    observers.observe(NSWindow.didResizeNotification, of: window) { [weak self] in
      self?.measure()
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

  func measure() {
    guard let window = hostWindow, let toolbar = window.toolbar,
      let ownIndex = toolbar.items.firstIndex(where: { item in
        item.view.map { isDescendant(of: $0) } ?? false
      })
    else { return }
    let visible = Set((toolbar.visibleItems ?? []).map(\.itemIdentifier))
    let own = toolbar.items[ownIndex]
    guard let ownView = own.view, visible.contains(own.itemIdentifier) else {
      // In the » menu itself, where it stands says nothing: made small, it comes back to the bar
      // and is measured there.
      measured?(ToolbarTitleLayout.unmeasuredWidth)
      return
    }
    let ownFrame = ownView.convert(ownView.bounds, to: nil)
    guard ownFrame.width > 0 else { return }
    var titleLeading = ownFrame.minX

    var centredWidth: CGFloat?
    var trailing: [(identifier: NSToolbarItem.Identifier, width: CGFloat, frame: NSRect?)] = []
    for (index, item) in toolbar.items.enumerated() where index != ownIndex {
      guard let view = item.view else { continue }
      observeFrame(of: view)
      let isOnBar = visible.contains(item.itemIdentifier)
      if isOnBar {
        widths[item.itemIdentifier] = view.fittingSize.width
      }
      let width = widths[item.itemIdentifier] ?? view.fittingSize.width
      if toolbar.centeredItemIdentifiers.contains(item.itemIdentifier) {
        // Both pickers can be centred at once — the conversation's and the web view's in a narrow
        // window — side by side; an item left empty takes nothing.
        if width > 0 {
          centredWidth = centredWidth.map { $0 + ToolbarTitleLayout.spacing + width } ?? width
        }
      } else if index < ownIndex {
        // An item before the title sent to the » menu — the sidebar's button, as the sidebar
        // folds — left its place to the title, and must find it again.
        if !isOnBar { titleLeading += width + ToolbarTitleLayout.spacing }
      } else {
        trailing.append(
          (item.itemIdentifier, width, isOnBar ? view.convert(view.bounds, to: nil) : nil))
      }
    }
    if let view = own.view { observeFrame(of: view) }
    // All on the bar, they are measured as they sit. Some of them in the » menu, the last
    // measurement may be older than a width that changed since — the status menu's label — and
    // they would never come back: the larger of it and of their widths, spaced, is taken.
    let identifiers = trailing.map(\.identifier)
    let frames = trailing.compactMap(\.frame)
    let extent: CGFloat
    if frames.count == trailing.count, let first = frames.first, let last = frames.last {
      extent = last.maxX - first.minX
      trailingExtents[identifiers] = extent
    } else {
      extent = max(
        trailingExtents[identifiers] ?? 0,
        ToolbarTitleLayout.estimatedExtent(of: trailing.map(\.width)))
    }
    measured?(
      ToolbarTitleLayout.room(
        titleLeading: titleLeading, windowWidth: window.frame.width,
        detailLeading: detailLeading, centredWidth: centredWidth, trailingExtent: extent))
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

/// Dragging the title moves the window, as the system's own title does: drawn by SwiftUI in the
/// toolbar, it kept the click for itself.
private struct MovesWindow: ViewModifier {
  func body(content: Content) -> some View {
    if #available(macOS 15, *) {
      content
        .gesture(WindowDragGesture())
        .allowsWindowActivationEvents(true)
    } else {
      content
    }
  }
}

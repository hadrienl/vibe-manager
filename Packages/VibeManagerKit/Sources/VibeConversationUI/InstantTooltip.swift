import AppKit
import SwiftUI

extension View {
  /// A tooltip shown a quarter of a second after the pointer comes over the view, rather than the
  /// system's, which waits seconds (#352): a glass bubble above the view, its arrow on it. Said to
  /// VoiceOver as the view's hint.
  ///
  /// With a `side`, the bubble opens beside the view rather than above it, its arrow on it: on the
  /// other side when that one has no room in the window.
  public func instantTooltip(_ text: Text, side: TooltipSide? = nil) -> some View {
    modifier(InstantTooltip(text: text, side: side))
  }

  /// No tooltip when `text` is nil.
  @_disfavoredOverload
  public func instantTooltip(_ text: Text?, side: TooltipSide? = nil) -> some View {
    modifier(InstantTooltip(text: text, side: side))
  }

  /// A string shown as it is; none when it is empty.
  @_disfavoredOverload
  public func instantTooltip<S: StringProtocol>(_ string: S, side: TooltipSide? = nil)
    -> some View
  {
    modifier(InstantTooltip(text: string.isEmpty ? nil : Text(string), side: side))
  }
}

/// The side of the view a tooltip opens on, in the layout's direction (#458).
public enum TooltipSide: Sendable {
  case leading
  case trailing

  /// On screen, as `direction` lays it out.
  func edge(in direction: LayoutDirection) -> TooltipEdge {
    switch (self, direction) {
    case (.leading, .leftToRight), (.trailing, .rightToLeft): .left
    default: .right
    }
  }
}

/// A side of the view, on screen: the bubble opens there, its arrow on its other side.
enum TooltipEdge: Equatable, Sendable {
  case left
  case right

  var opposite: Self { self == .left ? .right : .left }
}

private struct InstantTooltip: ViewModifier {
  let text: Text?
  var side: TooltipSide?
  @State private var isHovered = false
  @Environment(\.layoutDirection) private var direction

  // One structure whether there is a text or not: a help that comes and goes — a status's
  // detail — never rebuilds the view it is on.
  func body(content: Content) -> some View {
    content
      .onHover { isHovered = $0 }
      .onDisappear { isHovered = false }
      // Only while the pointer is over the view: a list of rows pays for nothing else.
      .background {
        if isHovered, let text { TooltipAnchor(text: text, edge: side?.edge(in: direction)) }
      }
      .accessibilityHint(text ?? Text(verbatim: ""))
  }
}

/// Stands behind the hovered view, the size of it: once in its window, it shows the bubble a
/// quarter of a second later, and takes it down when it leaves.
private struct TooltipAnchor: NSViewRepresentable {
  let text: Text
  let edge: TooltipEdge?

  func makeNSView(context: Context) -> TooltipAnchorView {
    let view = TooltipAnchorView()
    view.edge = edge
    view.text = text
    return view
  }

  func updateNSView(_ view: TooltipAnchorView, context: Context) {
    view.edge = edge
    view.text = text
  }

  static func dismantleNSView(_ view: TooltipAnchorView, coordinator: ()) {
    view.leave()
  }
}

private final class TooltipAnchorView: NSView {
  /// Shown again when it changes under a bubble already up: a chip's help that follows its state.
  var text = Text(verbatim: "") {
    didSet {
      if TooltipPresenter.shared.owner === self {
        TooltipPresenter.shared.show(text, from: self, edge: edge)
      }
    }
  }
  var edge: TooltipEdge?
  private var appearing: Task<Void, Never>?

  override func hitTest(_ point: NSPoint) -> NSView? { nil }

  override func viewDidMoveToWindow() {
    super.viewDidMoveToWindow()
    guard window != nil else {
      leave()
      return
    }
    appearing?.cancel()
    appearing = Task { @MainActor [weak self] in
      try? await Task.sleep(for: .milliseconds(250))
      guard !Task.isCancelled, let self, self.window != nil else { return }
      TooltipPresenter.shared.show(self.text, from: self, edge: self.edge)
    }
  }

  func leave() {
    appearing?.cancel()
    appearing = nil
    TooltipPresenter.shared.hide(from: self)
  }
}

/// The one bubble on screen, in a panel of its own above the window: drawn in the view's window, it
/// would be cut by the list, the scroll view or the toolbar the view stands in.
@MainActor
final class TooltipPresenter {
  static let shared = TooltipPresenter()
  /// Room around the bubble for the glass's shadow.
  static let inset: CGFloat = 10

  private(set) weak var owner: NSView?
  private var panel: NSPanel?
  private var hosting: NSHostingView<TooltipBubble>?
  private var monitor: Any?

  func show(_ text: Text, from view: NSView, edge: TooltipEdge? = nil) {
    guard let window = view.window, let screen = window.screen ?? NSScreen.main else { return }
    let anchor = window.convertToScreen(view.convert(view.bounds, to: nil))
    let placement = TooltipPlacement(
      size: TooltipBubble.size(of: text, sideways: edge != nil), anchor: anchor,
      window: window.frame, screen: screen.visibleFrame, edge: edge)
    let bubble = TooltipBubble(
      text: text, arrowX: placement.arrowX, pointsDown: placement.pointsDown,
      arrowEdge: placement.arrowEdge)
    let hosting = hosting ?? NSHostingView(rootView: bubble)
    self.hosting = hosting
    hosting.rootView = bubble

    let panel = panel ?? makePanel(content: hosting)
    self.panel = panel
    let wasShown = owner != nil && panel.isVisible
    owner = view
    panel.setFrame(placement.frame.insetBy(dx: -Self.inset, dy: -Self.inset), display: true)
    if panel.parent !== window {
      panel.parent?.removeChildWindow(panel)
      window.addChildWindow(panel, ordered: .above)
    }
    if !wasShown {
      panel.alphaValue = 0
      panel.orderFront(nil)
      if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
        panel.alphaValue = 1
      } else {
        NSAnimationContext.runAnimationGroup { context in
          context.duration = 0.12
          panel.animator().alphaValue = 1
        }
      }
    }
    // A click, a key or a scroll takes it down, as the system's.
    if monitor == nil {
      monitor = NSEvent.addLocalMonitorForEvents(
        matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown, .keyDown, .scrollWheel]
      ) { [weak self] event in
        self?.hide()
        return event
      }
    }
  }

  /// Takes the bubble down if `view` put it up.
  func hide(from view: NSView) {
    guard owner === view else { return }
    hide()
  }

  private func hide() {
    owner = nil
    if let monitor { NSEvent.removeMonitor(monitor) }
    monitor = nil
    guard let panel else { return }
    panel.parent?.removeChildWindow(panel)
    panel.orderOut(nil)
  }

  private func makePanel(content: NSView) -> NSPanel {
    let panel = NSPanel(
      contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered,
      defer: true)
    panel.isOpaque = false
    panel.backgroundColor = .clear
    panel.hasShadow = false
    panel.ignoresMouseEvents = true
    panel.isReleasedWhenClosed = false
    panel.hidesOnDeactivate = true
    panel.collectionBehavior = [.transient, .ignoresCycle, .fullScreenAuxiliary]
    let container = NSView()
    content.translatesAutoresizingMaskIntoConstraints = false
    container.addSubview(content)
    NSLayoutConstraint.activate([
      content.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: Self.inset),
      content.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -Self.inset),
      content.topAnchor.constraint(equalTo: container.topAnchor, constant: Self.inset),
      content.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -Self.inset),
    ])
    panel.contentView = container
    return panel
  }
}

/// Where the bubble stands, in screen coordinates (origin at the bottom): above the view and
/// centred on it, kept `margin` inside the window's sides; below it when the screen has no room
/// above. Beside the view on `edge`, when there is one: centred on it, on the other side when the
/// window has no room on that one, and kept inside the window all the same.
struct TooltipPlacement: Equatable {
  /// Between the arrow's tip and the view.
  static let gap: CGFloat = 3
  /// Kept between the bubble and the window's sides.
  static let margin: CGFloat = 8

  let frame: CGRect
  /// The arrow's tip, from the bubble's leading edge; from its top for an arrow on a side.
  let arrowX: CGFloat
  let pointsDown: Bool
  /// The bubble's side the arrow stands on, `nil` for one above or below the view.
  let arrowEdge: TooltipEdge?

  init(size: CGSize, anchor: CGRect, window: CGRect, screen: CGRect, edge: TooltipEdge? = nil) {
    let visible = window.intersection(screen)
    let sides = visible.isNull ? screen : visible
    if let edge {
      let fitsRight = anchor.maxX + Self.gap + size.width <= sides.maxX - Self.margin
      let fitsLeft = anchor.minX - Self.gap - size.width >= sides.minX + Self.margin
      let fits = edge == .right ? fitsRight : fitsLeft
      let fitsOther = edge == .right ? fitsLeft : fitsRight
      let opensOn = !fits && fitsOther ? edge.opposite : edge
      let beside =
        opensOn == .right ? anchor.maxX + Self.gap : anchor.minX - Self.gap - size.width
      let x = max(sides.minX + Self.margin, min(beside, sides.maxX - Self.margin - size.width))
      let centred = anchor.midY - size.height / 2
      let y = max(sides.minY + Self.margin, min(centred, sides.maxY - Self.margin - size.height))
      frame = CGRect(origin: CGPoint(x: x, y: y), size: size)
      // Clear of the bubble's corners when the window pushed it along the view.
      let clearance = TooltipBubbleShape.arrowClearance
      arrowX = max(clearance, min(frame.maxY - anchor.midY, size.height - clearance))
      pointsDown = false
      arrowEdge = opensOn.opposite
      return
    }
    arrowEdge = nil
    let centred = anchor.midX - size.width / 2
    let x = max(sides.minX + Self.margin, min(centred, sides.maxX - Self.margin - size.width))
    pointsDown = anchor.maxY + Self.gap + size.height <= screen.maxY
    let y = pointsDown ? anchor.maxY + Self.gap : anchor.minY - Self.gap - size.height
    frame = CGRect(origin: CGPoint(x: x, y: y), size: size)
    arrowX = anchor.midX - x
  }
}

struct TooltipBubble: View {
  /// The widest a bubble grows before its text wraps.
  static let maximumWidth: CGFloat = 250

  let text: Text
  let arrowX: CGFloat
  var pointsDown = true
  var arrowEdge: TooltipEdge?

  /// The bubble's size for its text: as wide as the text, up to `maximumWidth`.
  static func size(of text: Text, sideways: Bool = false) -> CGSize {
    let bubble = TooltipBubble(text: text, arrowX: 0, arrowEdge: sideways ? .left : nil)
    let fitting = NSHostingController(rootView: bubble)
      .sizeThatFits(in: CGSize(width: maximumWidth, height: .greatestFiniteMagnitude))
    return CGSize(width: ceil(fitting.width), height: ceil(fitting.height))
  }

  var body: some View {
    let shape = TooltipBubbleShape(arrowX: arrowX, pointsDown: pointsDown, arrowEdge: arrowEdge)
    let arrow = TooltipBubbleShape.arrowLength
    let vertical = arrowEdge == nil ? arrow : 0
    text
      .font(.callout)
      .foregroundStyle(.primary)
      .multilineTextAlignment(.leading)
      .fixedSize(horizontal: false, vertical: true)
      // Placed by the panel, laid out left to right whatever the language.
      .padding(.leading, 11 + (arrowEdge == .left ? arrow : 0))
      .padding(.trailing, 11 + (arrowEdge == .right ? arrow : 0))
      .padding(.top, 7 + (pointsDown ? 0 : vertical))
      .padding(.bottom, 7 + (pointsDown ? vertical : 0))
      .frame(
        minWidth: arrowEdge == nil ? 2 * TooltipBubbleShape.arrowClearance : nil,
        minHeight: arrowEdge == nil ? nil : 2 * TooltipBubbleShape.arrowClearance,
        alignment: .leading)
      .modifier(TooltipGlass(shape: shape))
  }
}

/// Liquid glass on macOS 26; before, the material popovers use, with their edge.
private struct TooltipGlass<S: Shape>: ViewModifier {
  let shape: S

  func body(content: Content) -> some View {
    if #available(macOS 26, *) {
      content.glassEffect(.regular, in: shape)
    } else {
      content
        .background(BehindWindowMaterial().clipShape(shape))
        .overlay { shape.stroke(.separator) }
        .compositingGroup()
        .shadow(color: .black.opacity(0.18), radius: 4, y: 1)
    }
  }
}

/// What lies behind the panel, blurred: a SwiftUI material only blurs its own window.
private struct BehindWindowMaterial: NSViewRepresentable {
  func makeNSView(context: Context) -> NSVisualEffectView {
    let view = NSVisualEffectView()
    view.material = .popover
    view.blendingMode = .behindWindow
    view.state = .active
    return view
  }

  func updateNSView(_ view: NSVisualEffectView, context: Context) {}
}

/// A rounded rectangle and its arrow, in one outline so the edge runs along the arrow rather than
/// across its base. The arrow takes the bottom `arrowLength` of the rect, or its top when it points
/// up; its left or right `arrowLength` when it stands on `arrowEdge`, `arrowX` then from the top.
struct TooltipBubbleShape: Shape {
  static let arrowLength: CGFloat = 6
  static let cornerRadius: CGFloat = 9
  /// The closest the arrow's tip comes to the bubble's sides.
  static let arrowClearance = cornerRadius + arrowLength
  let arrowX: CGFloat
  var pointsDown = true
  var arrowEdge: TooltipEdge?

  func path(in rect: CGRect) -> Path {
    if let arrowEdge {
      // The bubble pointing down, its axes swapped: the arrow on its right side.
      let swapped = CGRect(x: rect.minY, y: rect.minX, width: rect.height, height: rect.width)
      let right = downwardPath(in: swapped)
        .applying(CGAffineTransform(a: 0, b: 1, c: 1, d: 0, tx: 0, ty: 0))
      guard arrowEdge == .left else { return right }
      return right.applying(
        CGAffineTransform(a: -1, b: 0, c: 0, d: 1, tx: rect.minX + rect.maxX, ty: 0))
    }
    let path = downwardPath(in: rect)
    guard !pointsDown else { return path }
    return path.applying(
      CGAffineTransform(a: 1, b: 0, c: 0, d: -1, tx: 0, ty: rect.minY + rect.maxY))
  }

  private func downwardPath(in rect: CGRect) -> Path {
    let length = Self.arrowLength
    let body = CGRect(x: rect.minX, y: rect.minY, width: rect.width, height: rect.height - length)
    let radius = min(Self.cornerRadius, body.width / 2, body.height / 2)
    let x = min(max(rect.minX + arrowX, body.minX + radius + length), body.maxX - radius - length)
    var path = Path()
    path.move(to: CGPoint(x: body.minX + radius, y: body.minY))
    path.addArc(
      tangent1End: CGPoint(x: body.maxX, y: body.minY),
      tangent2End: CGPoint(x: body.maxX, y: body.maxY), radius: radius)
    path.addArc(
      tangent1End: CGPoint(x: body.maxX, y: body.maxY),
      tangent2End: CGPoint(x: body.minX, y: body.maxY), radius: radius)
    path.addLine(to: CGPoint(x: x + length, y: body.maxY))
    path.addLine(to: CGPoint(x: x, y: rect.maxY))
    path.addLine(to: CGPoint(x: x - length, y: body.maxY))
    path.addArc(
      tangent1End: CGPoint(x: body.minX, y: body.maxY),
      tangent2End: CGPoint(x: body.minX, y: body.minY), radius: radius)
    path.addArc(
      tangent1End: CGPoint(x: body.minX, y: body.minY),
      tangent2End: CGPoint(x: body.maxX, y: body.minY), radius: radius)
    path.closeSubpath()
    return path
  }
}

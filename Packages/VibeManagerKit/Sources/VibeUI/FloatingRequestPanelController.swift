import AppKit
import Carbon.HIToolbox
import Observation
import SwiftUI
import VibeApplication

/// The window of the floating panel (#41): a panel above the other applications, on every Space
/// and beside full-screen ones, that never activates Vibe Manager.
///
/// It is shown with `orderFrontRegardless()`, never made key by the application: the application
/// in front keeps the keyboard. A click on a button acts without taking it; a click in a text
/// field, or ⌃⌥⌘P, gives it the keyboard — and it is handed back as soon as the answer is sent.
final class FloatingPanelWindow: NSPanel {
  init() {
    super.init(
      contentRect: .zero, styleMask: [.nonactivatingPanel, .borderless], backing: .buffered,
      defer: true)
    isFloatingPanel = true
    level = .floating
    hidesOnDeactivate = false
    becomesKeyOnlyIfNeeded = true
    backgroundColor = .clear
    isOpaque = false
    hasShadow = false
    isMovable = false
    isExcludedFromWindowsMenu = true
    animationBehavior = .none
    collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
    setAccessibilityIdentifier("floating-request-panel-window")
  }

  // Borderless panels cannot take the keyboard by default; a free-text answer needs it.
  override var canBecomeKey: Bool { true }
  override var canBecomeMain: Bool { false }
}

/// A hosting view that acts on the first click — the panel's application is never the active
/// one — and says when its content takes another size, for the window to follow.
private final class FirstClickHostingView<Content: View>: NSHostingView<Content> {
  var sizeChanged: ((CGSize) -> Void)?

  override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

  override func invalidateIntrinsicContentSize() {
    super.invalidateIntrinsicContentSize()
    // Read once SwiftUI has finished the layout pass that changed it.
    DispatchQueue.main.async { [weak self] in
      guard let self else { return }
      self.sizeChanged?(self.intrinsicContentSize)
    }
  }
}

/// Shows and hides the floating panel as its model says, keeps it where the user put it on each
/// screen, and lends it the keyboard on ⌃⌥⌘P (#41).
@MainActor
public final class FloatingRequestPanelController {
  /// Space between the avatar and the edges of the screen, by default.
  static let defaultInset: CGFloat = 24
  /// Closer than this to an edge, the avatar snaps to it.
  static let snapDistance: CGFloat = 16

  private let model: AppModel
  private let panelModel: FloatingRequestPanelModel
  private let animator = AvatarAnimator()
  private var window: FloatingPanelWindow?
  /// Where the avatar's centre stands, in screen coordinates.
  private var anchor: CGPoint = .zero
  private var screen: NSScreen?
  /// Where the bubble opens, observed by the view: changing it keeps the view and its state.
  private let placement = FloatingPanelPlacement()
  private var layout: FloatingPanelLayout { placement.layout }
  private var contentSize: CGSize = .zero
  private var dragOrigin: CGPoint?
  private var hotKey: GlobalHotKey?
  /// The application that had the keyboard when the panel took it.
  private var lentBy: NSRunningApplication?
  private var screenObserver: NSObjectProtocol?

  public init?(model: AppModel) {
    guard let panelModel = model.floatingPanel else { return nil }
    self.model = model
    self.panelModel = panelModel
    screenObserver = NotificationCenter.default.addObserver(
      forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
    ) { [weak self] _ in
      MainActor.assumeIsolated { self?.screensChanged() }
    }
    observe()
  }

  // MARK: - Showing

  private func observe() {
    withObservationTracking {
      _ = panelModel.isShown
      _ = panelModel.positionResetCount
    } onChange: { [weak self] in
      Task { @MainActor in
        self?.update()
        self?.observe()
      }
    }
    update()
  }

  private func update() {
    if panelModel.isShown {
      show()
    } else {
      hide()
    }
  }

  private var resetsSeen = 0

  private func show() {
    let window = self.window ?? makeWindow()
    if resetsSeen != panelModel.positionResetCount {
      resetsSeen = panelModel.positionResetCount
      placeOnScreen(Self.screenUnderPointer())
    } else if !window.isVisible {
      // It comes where the user works: the screen of the pointer, at its place there.
      placeOnScreen(Self.screenUnderPointer())
    }
    guard !window.isVisible else { return }
    reposition()
    window.orderFrontRegardless()
    animator.start()
    // It comes because a request waits: the avatar calls for it.
    if let current = panelModel.current {
      animator.send(
        .requestArrived(
          speech: panelModel.isCollapsed ? nil : FloatingRequestPanelModel.speech(of: current)))
    }
    Announcer.floatingElement = window
    if hotKey == nil {
      hotKey = GlobalHotKey(
        keyCode: UInt32(kVK_ANSI_P), modifiers: UInt32(cmdKey | optionKey | controlKey)
      ) { [weak self] in self?.takeKeyboard() }
    }
  }

  private func hide() {
    hotKey = nil
    Announcer.floatingElement = nil
    // An ordered out window keeps its views: the animation is stopped here, not on disappear.
    animator.stop()
    guard let window, window.isVisible else { return }
    if window.isKeyWindow { releaseKeyboard() }
    window.orderOut(nil)
  }

  private func makeWindow() -> FloatingPanelWindow {
    let window = FloatingPanelWindow()
    window.contentView = hostingView()
    self.window = window
    return window
  }

  /// The window's size is the controller's to set, from the content's: the hosting view must not
  /// resize the window on its own, from its corner.
  private func hostingView() -> NSView {
    let view = FirstClickHostingView(rootView: content())
    view.sizingOptions = [.intrinsicContentSize]
    view.sizeChanged = { [weak self] size in self?.contentSizeChanged(size) }
    contentSize = view.intrinsicContentSize
    return view
  }

  private func content() -> some View {
    FloatingRequestPanelHost(controller: self)
  }

  /// What the SwiftUI side needs.
  fileprivate var viewState:
    (AppModel, FloatingRequestPanelModel, AvatarAnimator, FloatingPanelPlacement)
  {
    (model, panelModel, animator, placement)
  }

  // MARK: - Placing

  private func placeOnScreen(_ screen: NSScreen?) {
    guard let screen = screen ?? NSScreen.main ?? NSScreen.screens.first else { return }
    self.screen = screen
    let frame = screen.visibleFrame
    let half = FloatingRequestPanel.avatarSize / 2 + FloatingRequestPanel.padding
    if let key = Self.key(of: screen), let saved = panelModel.anchor(forDisplay: key) {
      anchor = CGPoint(
        x: frame.minX + saved.x * frame.width, y: frame.minY + saved.y * frame.height)
    } else {
      anchor = CGPoint(
        x: frame.maxX - Self.defaultInset - half, y: frame.minY + Self.defaultInset + half)
    }
    anchor = Self.clamp(anchor, in: frame, margin: half)
    relayout()
  }

  /// The bubble opens toward the inside of the screen.
  private func relayout() {
    guard let frame = screen?.visibleFrame else { return }
    let newLayout = FloatingPanelLayout(
      bubbleLeading: anchor.x > frame.midX, alignedBottom: anchor.y < frame.midY)
    if newLayout != layout { placement.layout = newLayout }
    placement.maxBubbleHeight = frame.height * 0.6
    reposition()
  }

  /// The content took a new size: the window follows, the avatar stays where it stands.
  fileprivate func contentSizeChanged(_ size: CGSize) {
    guard size != contentSize else { return }
    contentSize = size
    reposition()
  }

  private func reposition() {
    guard let window else { return }
    guard contentSize.width > 0, contentSize.height > 0 else { return }
    let half = FloatingRequestPanel.avatarSize / 2 + FloatingRequestPanel.padding
    let avatarX = layout.bubbleLeading ? contentSize.width - half : half
    let avatarY = layout.alignedBottom ? half : contentSize.height - half
    let origin = CGPoint(x: anchor.x - avatarX, y: anchor.y - avatarY)
    window.setFrame(CGRect(origin: origin, size: contentSize), display: true)
  }

  fileprivate func dragged(by delta: CGSize?) {
    guard let delta else {
      endDrag()
      return
    }
    let origin = dragOrigin ?? anchor
    dragOrigin = origin
    anchor = CGPoint(x: origin.x + delta.width, y: origin.y + delta.height)
    reposition()
  }

  /// Snapped to the nearest edges, kept on a screen, and remembered for that screen.
  private func endDrag() {
    dragOrigin = nil
    let screen =
      NSScreen.screens.first { $0.frame.contains(anchor) } ?? self.screen ?? NSScreen.main
    guard let screen else { return }
    self.screen = screen
    let frame = screen.visibleFrame
    let half = FloatingRequestPanel.avatarSize / 2 + FloatingRequestPanel.padding
    var point = Self.clamp(anchor, in: frame, margin: half)
    if point.x - half - frame.minX < Self.snapDistance { point.x = frame.minX + half }
    if frame.maxX - point.x - half < Self.snapDistance { point.x = frame.maxX - half }
    if point.y - half - frame.minY < Self.snapDistance { point.y = frame.minY + half }
    if frame.maxY - point.y - half < Self.snapDistance { point.y = frame.maxY - half }
    anchor = point
    if let key = Self.key(of: screen) {
      panelModel.setAnchor(
        FloatingPanelAnchor(
          x: (point.x - frame.minX) / frame.width, y: (point.y - frame.minY) / frame.height),
        forDisplay: key)
    }
    relayout()
  }

  /// A screen came or went: the panel goes back to its place on a screen still there.
  private func screensChanged() {
    guard let window, window.isVisible else { return }
    // Screens are other objects after a reconfiguration: told apart by their identifier.
    let current = screen.flatMap(Self.key(of:))
    if let current, let same = NSScreen.screens.first(where: { Self.key(of: $0) == current }) {
      placeOnScreen(same)
    } else {
      placeOnScreen(NSScreen.main)
    }
  }

  static func clamp(_ point: CGPoint, in frame: CGRect, margin: CGFloat) -> CGPoint {
    CGPoint(
      x: min(max(point.x, frame.minX + margin), frame.maxX - margin),
      y: min(max(point.y, frame.minY + margin), frame.maxY - margin))
  }

  static func screenUnderPointer() -> NSScreen? {
    let pointer = NSEvent.mouseLocation
    return NSScreen.screens.first { $0.frame.contains(pointer) }
  }

  /// The screen's identifier, stable across launches and reconnections.
  static func key(of screen: NSScreen) -> String? {
    guard
      let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")]
        as? NSNumber,
      let uuid = CGDisplayCreateUUIDFromDisplayID(number.uint32Value)?.takeRetainedValue()
    else { return nil }
    return CFUUIDCreateString(nil, uuid) as String
  }

  // MARK: - Keyboard

  /// ⌃⌥⌘P: the bubble takes the keyboard, without Vibe Manager coming forward.
  private func takeKeyboard() {
    guard let window, window.isVisible else { return }
    if window.isKeyWindow {
      releaseKeyboard()
      return
    }
    lentBy = NSWorkspace.shared.frontmostApplication
    panelModel.focus()
    window.makeKey()
  }

  /// Hands the keyboard back to the application that had it.
  fileprivate func releaseKeyboard() {
    guard let window, window.isKeyWindow else { return }
    // The application that had it becomes key again, and the panel stops being.
    let owner = lentBy ?? NSWorkspace.shared.frontmostApplication
    lentBy = nil
    if let owner, owner != NSRunningApplication.current {
      owner.activate()
    }
    // Activating an application already active may do nothing: the panel stops being key by
    // leaving the screen and coming back, without taking anything.
    if window.isKeyWindow {
      window.orderOut(nil)
      window.orderFrontRegardless()
    }
  }
}

/// Where the bubble opens and how tall it may grow, for the view to follow.
@MainActor
@Observable
final class FloatingPanelPlacement {
  var layout = FloatingPanelLayout()
  var maxBubbleHeight: CGFloat = 480
}

/// The SwiftUI side of the panel.
private struct FloatingRequestPanelHost: View {
  let controller: FloatingRequestPanelController

  var body: some View {
    let (model, panel, animator, placement) = controller.viewState
    FloatingRequestPanel(
      model: model, panel: panel, animator: animator, layout: placement.layout,
      maxBubbleHeight: placement.maxBubbleHeight,
      onDrag: { controller.dragged(by: $0) },
      onReleaseKeyboard: { controller.releaseKeyboard() }
    )
  }
}

/// A shortcut heard in every application, registered with Carbon: no accessibility permission is
/// needed. Unregistered when released.
/// Unchecked: Carbon calls it on the main thread, where it was registered and where it acts.
final class GlobalHotKey: @unchecked Sendable {
  nonisolated(unsafe) private var reference: EventHotKeyRef?
  nonisolated(unsafe) private var handler: EventHandlerRef?
  private let action: @MainActor () -> Void

  init?(keyCode: UInt32, modifiers: UInt32, action: @escaping @MainActor () -> Void) {
    self.action = action
    var type = EventTypeSpec(
      eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
    let context = Unmanaged.passUnretained(self).toOpaque()
    let installed = InstallEventHandler(
      GetApplicationEventTarget(),
      { _, event, context in
        guard let context, let event else { return OSStatus(eventNotHandledErr) }
        // Only this shortcut: another part of the application may register its own.
        var pressed = EventHotKeyID()
        let status = GetEventParameter(
          event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil,
          MemoryLayout<EventHotKeyID>.size, nil, &pressed)
        guard status == noErr, pressed.signature == GlobalHotKey.signature, pressed.id == 1
        else { return OSStatus(eventNotHandledErr) }
        let hotKey = Unmanaged<GlobalHotKey>.fromOpaque(context).takeUnretainedValue()
        MainActor.assumeIsolated { hotKey.action() }
        return noErr
      }, 1, &type, context, &handler)
    let identifier = EventHotKeyID(signature: Self.signature, id: 1)
    let registered = RegisterEventHotKey(
      keyCode, modifiers, identifier, GetApplicationEventTarget(), 0, &reference)
    // Taken by another application, or refused: no shortcut, and `deinit` releases what was
    // installed — once.
    guard installed == noErr, registered == noErr else { return nil }
  }

  /// "VMfp": Vibe Manager's floating panel.
  static let signature = OSType(0x564D_6670)

  deinit {
    if let reference { UnregisterEventHotKey(reference) }
    if let handler { RemoveEventHandler(handler) }
  }
}

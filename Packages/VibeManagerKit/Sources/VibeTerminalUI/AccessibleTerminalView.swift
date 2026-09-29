import AppKit
import SwiftTerm
import VibeApplication

/// SwiftTerm's view, readable by VoiceOver.
///
/// SwiftTerm 1.20.0 exposes nothing to accessibility on the Mac: its service is a stub, and the
/// terminal was a silent rectangle. This makes it one read-only text area whose value is the
/// screen as it is now — the visible lines, not the scrollback — and whose label names the
/// session and what its agent is doing. Output is never announced as it arrives: an agent writing
/// fifty lines a second would make VoiceOver unusable. Read Last Output (⌃⌥⌘O) says the last lines
/// on demand.
public final class AccessibleTerminalView: TerminalView {
  /// "Terminal — <session> — <agent state>", set by the surface.
  public var accessibilityTitle = String(localized: "Terminal", bundle: .module)

  public override func isAccessibilityElement() -> Bool { true }

  public override func accessibilityRole() -> NSAccessibility.Role? { .textArea }

  public override func accessibilityRoleDescription() -> String? {
    String(localized: "terminal", bundle: .module, comment: "What VoiceOver calls the element.")
  }

  public override func accessibilityLabel() -> String? { accessibilityTitle }

  /// Told when the view joins a window, or leaves one: what follows the keyboard is installed on
  /// the window, and SwiftUI may update the view before it has one.
  var onWindowChange: (() -> Void)?

  /// The size a hidden terminal was given, held back while the column keeps changing (#150).
  ///
  /// Every session's terminal stays mounted, hidden behind the one on screen, and a new size
  /// makes SwiftTerm reflow the whole scrollback — ten thousand lines and more. Folding the
  /// sidebar, or opening the web view, narrows the column one animation frame at a time: every
  /// hidden terminal reflowed at every frame, on the main thread, and the animation stuttered.
  ///
  /// A hidden terminal is not drawn, so it waits for the size to settle — `settleDelay` without a
  /// new one, the end of a live resize, or being shown — and then takes the last one, in a single
  /// reflow, and tells its program. It must not wait for longer: a session shown as a
  /// conversation keeps its terminal hidden, and the agent formats what it writes for the width
  /// its terminal reports; a session restored behind the one on screen starts its agent at the
  /// first size its terminal got, often one of the layout's intermediate passes.
  private(set) var deferredSize: NSSize?

  /// How long a hidden terminal's size must stay unchanged before it is taken: longer than the
  /// frames of an animation are apart, short enough that a program is told almost at once.
  var settleDelay: Duration = .milliseconds(250)

  private var settleTask: Task<Void, Never>?

  public override func setFrameSize(_ newSize: NSSize) {
    // Its first size is never held back: the program cannot start without one.
    if isHidden, !frame.size.equalTo(.zero) {
      deferredSize = newSize.equalTo(frame.size) ? nil : newSize
      scheduleSettle()
      return
    }
    deferredSize = nil
    settleTask?.cancel()
    settleTask = nil
    super.setFrameSize(newSize)
  }

  private func scheduleSettle() {
    settleTask?.cancel()
    settleTask = nil
    guard deferredSize != nil else { return }
    let delay = settleDelay
    settleTask = Task { @MainActor [weak self] in
      try? await Task.sleep(for: delay)
      guard !Task.isCancelled else { return }
      self?.applyDeferredSize()
    }
  }

  /// Takes the size held back, if there is one.
  func applyDeferredSize() {
    settleTask?.cancel()
    settleTask = nil
    guard let size = deferredSize else { return }
    deferredSize = nil
    super.setFrameSize(size)
  }

  public override func viewDidEndLiveResize() {
    super.viewDidEndLiveResize()
    applyDeferredSize()
  }

  public override func viewDidUnhide() {
    applyDeferredSize()
    super.viewDidUnhide()
  }

  public override func viewDidMoveToWindow() {
    super.viewDidMoveToWindow()
    installLinkPointer()
    onWindowChange?()
  }

  // MARK: - Links (#186)

  /// Whether a click without ⌘ opens a link, or reaches the waiting double click.
  let linkClicks = TerminalLinkClicks()

  /// Told of a link chosen from the terminal's menu, with how to open it.
  var openLinkFromMenu: ((String, LinkGesture) -> Void)?
  /// Whether the session has a web view the menu of a link can offer.
  var hasWebView: () -> Bool = { false }

  /// Whether the program in the terminal follows the mouse: then a click is its own, and a link
  /// opens with ⌘-click only.
  var programFollowsMouse: Bool {
    allowMouseReporting && getTerminal().mouseMode != .off
  }

  /// A plain click opens a link, and hovering one underlines it — unless the program follows the
  /// mouse. SwiftTerm looks for a link before it hands a release to the program: in `.hover` it
  /// would open the link and never send the release. Called before each gesture is read, so that a
  /// program that turns the mouse on or off is followed from the next one.
  func syncLinkMode() {
    let wanted: LinkHighlightMode = programFollowsMouse ? .hoverWithModifier : .hover
    // The setter redraws the whole screen: only on a change.
    if linkHighlightMode != wanted { linkHighlightMode = wanted }
  }

  public override func mouseDown(with event: NSEvent) {
    linkClicks.pointerDown()
    syncLinkMode()
    // Under a program that follows the mouse, a ⌘-click on a link opens it on the release, which
    // SwiftTerm then does not send on: the program would be told of a press that never ends. It
    // is told of neither.
    if event.modifierFlags.contains(.command), programFollowsMouse, link(at: event) != nil {
      return
    }
    super.mouseDown(with: event)
  }

  public override func menu(for event: NSEvent) -> NSMenu? {
    guard let link = link(at: event), let url = TerminalPaneModel.url(fromLink: link) else {
      return super.menu(for: event)
    }
    let menu = NSMenu()
    for action in LinkMenuAction.actions(for: url, hasWebView: hasWebView()) {
      let item = LinkMenuItem(title: action.title) { [weak self] in
        if let gesture = action.gesture {
          self?.openLinkFromMenu?(link, gesture)
        } else {
          NSPasteboard.general.clearContents()
          NSPasteboard.general.setString(url.absoluteString, forType: .string)
        }
      }
      menu.addItem(item)
    }
    return menu
  }

  /// The cell under a point of the view, on the screen rather than in the scrollback.
  func cell(at point: NSPoint) -> Position? {
    let terminal = getTerminal()
    guard let (width, height) = cellSize, width > 0, height > 0 else { return nil }
    let column = Int(point.x / width)
    let row = Int((frame.height - point.y) / height)
    guard (0..<terminal.cols).contains(column), (0..<terminal.rows).contains(row) else {
      return nil
    }
    return Position(col: column, row: row)
  }

  /// The size of a cell, exactly as SwiftTerm lays them out: its own size is not public, and
  /// `cellSizeInPixels` rounds it to the pixel, which puts a click far right several columns off.
  /// The optimal frame is the cells' size times the grid, plus the scroller when it shows.
  private var cellSize: (width: CGFloat, height: CGFloat)? {
    let terminal = getTerminal()
    guard terminal.cols > 0, terminal.rows > 0 else { return nil }
    let frame = getOptimalFrameSize()
    // The width SwiftTerm reserves for its scroller, unless it hides it.
    let scroller = subviews.lazy.compactMap { $0 as? NSScroller }.first
    let reserved =
      scroller.map { $0.isHidden ? 0 : NSScroller.scrollerWidth(for: .regular, scrollerStyle: scrollerStyle) }
      ?? 0
    let width = frame.width - reserved
    return (width / CGFloat(terminal.cols), frame.height / CGFloat(terminal.rows))
  }

  /// The link at a cell of the screen: an OSC 8 address, or text that reads as one.
  func link(atScreen cell: Position) -> String? {
    getTerminal().link(at: .screen(cell), mode: .explicitAndImplicit)
  }

  func link(at event: NSEvent) -> String? {
    cell(at: convert(event.locationInWindow, from: nil)).flatMap(link(atScreen:))
  }

  // MARK: Pointer

  /// SwiftTerm shows the I-beam everywhere, and its `mouseMoved` cannot be overridden from here: a
  /// tracking area of our own shows the pointing hand over what a click opens.
  private var linkPointer: LinkPointer?
  private var showsHand = false

  private func installLinkPointer() {
    guard window != nil, linkPointer == nil else { return }
    let pointer = LinkPointer(view: self)
    addTrackingArea(
      NSTrackingArea(
        rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect],
        owner: pointer))
    linkPointer = pointer
    syncLinkMode()
  }

  fileprivate func pointerMoved(_ event: NSEvent) {
    syncLinkMode()
    let cell = cell(at: convert(event.locationInWindow, from: nil))
    // Looked up at every move, as SwiftTerm does for its underline: output scrolling under a still
    // pointer changes what is under it.
    let pointerIsOnLink =
      cell.flatMap(link(atScreen:)).map(TerminalPaneModel.opensOnClick) ?? false
    let clickable =
      pointerIsOnLink && (!programFollowsMouse || event.modifierFlags.contains(.command))
    if clickable {
      NSCursor.pointingHand.set()
    } else if showsHand {
      NSCursor.iBeam.set()
    }
    showsHand = clickable
  }

  fileprivate func pointerExited() {
    showsHand = false
  }

  public override func accessibilityValue() -> Any? {
    TerminalText.visibleScreen(of: getTerminal())
  }

  public override func isAccessibilityFocused() -> Bool {
    window?.firstResponder === self
  }

  public override func accessibilityHelp() -> String? {
    String(
      localized:
        "Read Last Output, Control-Option-Command-O, reads the last lines the agent wrote.",
      bundle: .module, comment: "Read Last Output is a command of the View menu.")
  }
}

/// Receives the moves over the terminal for its pointer: SwiftTerm's own tracking areas send them
/// to the view, whose handler is not ours to extend.
private final class LinkPointer: NSResponder {
  private weak var view: AccessibleTerminalView?

  init(view: AccessibleTerminalView) {
    self.view = view
    super.init()
  }

  required init?(coder: NSCoder) { nil }

  override func mouseMoved(with event: NSEvent) {
    view?.pointerMoved(event)
  }

  override func mouseExited(with event: NSEvent) {
    view?.pointerExited()
  }
}

/// A menu item that runs a closure.
final class LinkMenuItem: NSMenuItem {
  private let perform: () -> Void

  init(title: String, perform: @escaping () -> Void) {
    self.perform = perform
    super.init(title: title, action: #selector(run), keyEquivalent: "")
    target = self
  }

  required init(coder: NSCoder) { fatalError("init(coder:) is not used") }

  @objc private func run() {
    perform()
  }
}

/// Text out of a terminal, for people rather than for a terminal.
public enum TerminalText {
  /// The screen's lines, trailing blanks and trailing empty lines removed.
  public static func visibleScreen(of terminal: Terminal) -> String {
    var lines: [String] = []
    for row in 0..<terminal.rows {
      let text = terminal.getLine(row: row)?.translateToString(trimRight: true) ?? ""
      // Cells never written read as NUL, which is nothing to say.
      lines.append(
        text.replacingOccurrences(of: "\u{0}", with: " ").trimmingCharacters(in: .whitespaces))
    }
    while lines.last?.isEmpty == true { lines.removeLast() }
    return lines.joined(separator: "\n")
  }

  /// The last `count` lines that say something, out of what a program wrote: escape sequences
  /// removed, a line rewritten by carriage returns reduced to what it ended as.
  public static func lastLines(of bytes: [UInt8], count: Int) -> [String] {
    let plain = stripEscapes(String(decoding: bytes.suffix(64 * 1024), as: UTF8.self))
    var lines: [String] = []
    var line = String.UnicodeScalarView()
    var scalars = Array(plain.unicodeScalars)[...]
    func finish() {
      let trimmed = String(line).trimmingCharacters(in: .whitespaces)
      if !trimmed.isEmpty { lines.append(trimmed) }
      line = String.UnicodeScalarView()
    }
    // Scalars, not characters: `\r\n` is one `Character`, and neither `\r` nor `\n`.
    while let scalar = scalars.popFirst() {
      switch scalar {
      case "\n":
        finish()
      case "\r":
        if scalars.first == "\n" {
          scalars.removeFirst()
          finish()
        } else {
          // A carriage return starts the line over: what follows is what shows.
          line = String.UnicodeScalarView()
        }
      default:
        line.append(scalar)
      }
    }
    finish()
    return Array(lines.suffix(count))
  }

  /// CSI, OSC and two-character escape sequences, and the other control characters but the line
  /// endings, removed.
  static func stripEscapes(_ text: String) -> String {
    var output = String.UnicodeScalarView()
    var scalars = text.unicodeScalars.makeIterator()
    while let scalar = scalars.next() {
      switch scalar {
      case "\u{1B}":
        guard let next = scalars.next() else { break }
        if next == "[" {
          // CSI: parameters and intermediates, up to a final byte in @…~.
          while let byte = scalars.next(), !(0x40...0x7E).contains(byte.value) {}
        } else if next == "]" {
          // OSC: up to BEL or ST.
          var previous: Unicode.Scalar?
          while let byte = scalars.next() {
            if byte == "\u{07}" || (previous == "\u{1B}" && byte == "\\") { break }
            previous = byte
          }
        }
      case "\n", "\r", "\t":
        output.append(scalar)
      default:
        if scalar.value >= 0x20, scalar.value != 0x7F { output.append(scalar) }
      }
    }
    return String(output)
  }
}

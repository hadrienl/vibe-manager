import AppKit
import VibeApplication
import WebKit

/// How the user opens a link of a page in a new tab, as in Safari (#186): ⌘-click and the middle
/// button in the background, ⇧⌘-click in front. What an agent does is never read this way.
enum BrowserLinkGesture {
  enum Decision: Equatable {
    case sameTab
    case newTab(activate: Bool)
  }

  enum Button: Equatable {
    case primary
    case middle
    case other

    /// `WKNavigationAction.buttonNumber` is a mask, not an index: 1 the left button, 2 the right,
    /// 4 the middle (`WebEventFactory::toNSButtonNumber`).
    init(webKitButtonNumber number: Int) {
      switch number {
      case 1 << 0: self = .primary
      case 1 << 2: self = .middle
      default: self = .other
      }
    }
  }

  static func decide(
    modifiers: NSEvent.ModifierFlags, button: Button, isLink: Bool, isAgentDriven: Bool
  ) -> Decision {
    guard isLink, !isAgentDriven else { return .sameTab }
    if button == .middle { return .newTab(activate: false) }
    guard modifiers.contains(.command) else { return .sameTab }
    return .newTab(activate: modifiers.contains(.shift))
  }

  /// An address of this Mac opens from a page of this Mac only: from a site, WebKit refuses to
  /// follow a link to a file, and a new tab must not be the way around it.
  static func mayOpen(_ target: URL, from page: URL?) -> Bool {
    !target.isFileURL || page?.isFileURL == true
  }

  @MainActor
  static func decide(_ action: WKNavigationAction, isAgentDriven: Bool) -> Decision {
    decide(
      modifiers: action.modifierFlags, button: Button(webKitButtonNumber: action.buttonNumber),
      isLink: action.navigationType == .linkActivated, isAgentDriven: isAgentDriven)
  }
}

/// The context menu WebKit shows over a link, with the actions every link has (#186): its Open
/// Link in New Window opens a tab of the session, and Open in the External Browser follows it.
@MainActor
enum BrowserLinkMenu {
  // The identifiers WebKit gives its items: public on iOS only, the same strings on the Mac.
  static let newWindowIdentifier = NSUserInterfaceItemIdentifier(
    "WKMenuItemIdentifierOpenLinkInNewWindow")
  static let copyLinkIdentifier = NSUserInterfaceItemIdentifier("WKMenuItemIdentifierCopyLink")

  /// Changes the menu in place, when it is a link's and the link shows a page.
  static func rewrite(
    _ menu: NSMenu, link: URL?, openInNewTab: @escaping (URL) -> Void,
    openExternally: @escaping (URL) -> Void
  ) {
    guard let link, LinkRouting.isPage(link) else { return }
    let items = menu.items
    let newWindow = items.firstIndex { $0.identifier == newWindowIdentifier }
    guard let anchor = newWindow ?? items.firstIndex(where: { $0.identifier == copyLinkIdentifier })
    else { return }
    var index = anchor
    if let newWindow {
      menu.removeItem(at: newWindow)
      menu.insertItem(
        BrowserMenuItem(title: LinkMenuAction.openInNewTab.title) { openInNewTab(link) },
        at: newWindow)
      index = newWindow + 1
    }
    menu.insertItem(
      BrowserMenuItem(title: LinkMenuAction.openInExternalBrowser.title) { openExternally(link) },
      at: index)
  }
}

/// A menu item that runs a closure.
final class BrowserMenuItem: NSMenuItem {
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

/// A page of a session: its three-finger tap and its menu know the link under the pointer (#186).
///
/// WebKit tells nothing of what the pointer is over. A script of its own world, in every frame,
/// says which link it enters and leaves: the page can neither see it nor speak for it.
final class SessionWebView: WKWebView {
  /// The link under the pointer, as the page's script last said: forgotten when the pointer
  /// leaves the view and when another page commits, which no pointer event would say.
  var hoveredLink: URL?
  var openInBackgroundTab: ((URL) -> Void)?
  var openExternally: ((URL) -> Void)?
  /// Told when the user clicks in the page or types into it — never of a click the page's script
  /// or an agent dispatches, which are not AppKit events (#241).
  var onUserInput: (() -> Void)?

  /// Whether an event of the user's hands the tab back to them: a click of the main button, or
  /// keys that type text. A right click, a scroll with Space or the arrows, a shortcut do not: a
  /// page that asks for any of them must not win the tab with it (#241).
  static func handsTabBack(_ event: NSEvent) -> Bool {
    let shortcut = !event.modifierFlags.intersection([.command, .control]).isEmpty
    switch event.type {
    case .leftMouseDown:
      return !shortcut
    case .keyDown:
      guard !shortcut, let characters = event.characters else { return false }
      return characters.unicodeScalars.contains { scalar in
        // AppKit gives the arrows and function keys characters of the private use area.
        !(0xF700...0xF8FF).contains(scalar.value)
          && !CharacterSet.whitespacesAndNewlines.contains(scalar)
          && !CharacterSet.controlCharacters.contains(scalar)
      }
    default:
      return false
    }
  }

  /// A press of the user's, as a gesture that opens a tab or an application must follow.
  func notePress(at time: TimeInterval, modifiers: NSEvent.ModifierFlags) {
    lastPress = (time, modifiers)
  }
  /// When the user last pressed or let go of a button over the page, and with which keys pressed:
  /// a gesture that opens a tab must follow one, not a click the page's script made up. WebKit
  /// follows a link on the release, however long the press lasted.
  private(set) var lastPress: (time: TimeInterval, modifiers: NSEvent.ModifierFlags)?

  /// The hovered link, when the page may have it opened: an address of this Mac only from a page
  /// of this Mac, as WebKit decides for a click.
  var openableHoveredLink: URL? {
    guard let link = hoveredLink else { return nil }
    return BrowserLinkGesture.mayOpen(link, from: url) ? link : nil
  }

  /// Whether a gesture read on a navigation follows a press of the user's, with the same keys.
  func followsPress(with modifiers: NSEvent.ModifierFlags, now: TimeInterval) -> Bool {
    guard let lastPress, now - lastPress.time < 1 else { return false }
    let keys: NSEvent.ModifierFlags = [.command, .shift, .option, .control]
    return lastPress.modifiers.intersection(keys) == modifiers.intersection(keys)
  }

  override func mouseDown(with event: NSEvent) {
    notePress(at: event.timestamp, modifiers: event.modifierFlags)
    if Self.handsTabBack(event) { onUserInput?() }
    super.mouseDown(with: event)
  }

  override func otherMouseDown(with event: NSEvent) {
    notePress(at: event.timestamp, modifiers: event.modifierFlags)
    super.otherMouseDown(with: event)
  }

  override func keyDown(with event: NSEvent) {
    if Self.handsTabBack(event) { onUserInput?() }
    super.keyDown(with: event)
  }

  override func mouseUp(with event: NSEvent) {
    lastPress?.time = event.timestamp
    super.mouseUp(with: event)
  }

  override func otherMouseUp(with event: NSEvent) {
    lastPress?.time = event.timestamp
    super.otherMouseUp(with: event)
  }

  override func mouseExited(with event: NSEvent) {
    hoveredLink = nil
    super.mouseExited(with: event)
  }

  /// A three-finger tap — or a force click, as the trackpad is set — on a link opens it in a tab
  /// behind; elsewhere, macOS looks the word up as it always does.
  override func quickLook(with event: NSEvent) {
    if let link = openableHoveredLink, LinkRouting.isPage(link), let openInBackgroundTab {
      openInBackgroundTab(link)
      return
    }
    super.quickLook(with: event)
  }

  override func willOpenMenu(_ menu: NSMenu, with event: NSEvent) {
    super.willOpenMenu(menu, with: event)
    guard let openInBackgroundTab, let openExternally else { return }
    BrowserLinkMenu.rewrite(
      menu, link: openableHoveredLink, openInNewTab: openInBackgroundTab,
      openExternally: openExternally)
  }
}

/// Receives the link the pointer is over, from the script of the links' world.
final class HoveredLinkHandler: NSObject, WKScriptMessageHandler {
  weak var webView: SessionWebView?

  init(webView: SessionWebView) {
    self.webView = webView
  }

  func userContentController(
    _ userContentController: WKUserContentController, didReceive message: WKScriptMessage
  ) {
    let link = (message.body as? String).flatMap(URL.init(string:))
    MainActor.assumeIsolated {
      webView?.hoveredLink = link
    }
  }
}

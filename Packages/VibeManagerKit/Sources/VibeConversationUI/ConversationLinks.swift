import AppKit
import SwiftUI
import VibeApplication

/// How a conversation opens its links: the session's rule, set by the workspace (#186). Unset — a
/// preview, a test — links go where SwiftUI's `openURL` sends them.
public struct ConversationLinks: Sendable {
  public var open: @MainActor @Sendable (URL, LinkGesture) -> Void
  /// Whether the session has a web view, for the menu of a link.
  public var hasWebView: @MainActor @Sendable () -> Bool

  public init(
    open: @escaping @MainActor @Sendable (URL, LinkGesture) -> Void,
    hasWebView: @escaping @MainActor @Sendable () -> Bool
  ) {
    self.open = open
    self.hasWebView = hasWebView
  }

  /// A click, which follows Settings, and ⌥ read from the click itself.
  @MainActor
  public func click(_ url: URL) {
    let flags = NSApp.currentEvent?.modifierFlags ?? NSEvent.modifierFlags
    open(url, .click(alternate: flags.contains(.option)))
  }

  @MainActor
  func perform(_ action: LinkMenuAction, on url: URL) {
    if let gesture = action.gesture {
      open(url, gesture)
    } else {
      LinkPasteboard.copy(url)
    }
  }

  @MainActor
  func actions(for url: URL) -> [LinkMenuAction] {
    LinkMenuAction.actions(for: url, hasWebView: hasWebView())
  }
}

private struct ConversationLinksKey: EnvironmentKey {
  static let defaultValue: ConversationLinks? = nil
}

extension EnvironmentValues {
  public var conversationLinks: ConversationLinks? {
    get { self[ConversationLinksKey.self] }
    set { self[ConversationLinksKey.self] = newValue }
  }
}

enum LinkPasteboard {
  @MainActor
  static func copy(_ url: URL) {
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(url.absoluteString, forType: .string)
  }
}

/// The menu items of a link, for a text view's menu. Without the session's rule, only Copy Link.
@MainActor
enum LinkMenuItems {
  static func items(for url: URL, links: ConversationLinks?) -> [NSMenuItem] {
    let actions = links?.actions(for: url) ?? [.copy]
    return actions.map { action in
      ClosureMenuItem(title: action.title) {
        if let links {
          links.perform(action, on: url)
        } else {
          LinkPasteboard.copy(url)
        }
      }
    }
  }

  /// The items a text view adds by itself over a link — Open Link, Copy Link — which ours replace.
  static func isTextViewLinkItem(_ item: NSMenuItem) -> Bool {
    guard !(item is ClosureMenuItem), let action = item.action else { return false }
    return NSStringFromSelector(action).localizedCaseInsensitiveContains("link")
  }
}

/// A menu item that runs a closure.
final class ClosureMenuItem: NSMenuItem {
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

/// The actions of a link, for a SwiftUI menu.
struct LinkMenuButtons: View {
  let url: URL
  @Environment(\.conversationLinks) private var links

  var body: some View {
    ForEach(links?.actions(for: url) ?? [.copy], id: \.title) { action in
      Button(action.title) {
        if let links {
          links.perform(action, on: url)
        } else {
          LinkPasteboard.copy(url)
        }
      }
    }
  }
}

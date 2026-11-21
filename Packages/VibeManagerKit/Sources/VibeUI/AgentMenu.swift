import AppKit
import VibeApplication
import VibeDomain

/// What the agent's menu shows (#575), in words and symbols: what `AgentMenu` draws, and what a
/// test reads without opening anything.
struct AgentMenuContent: Equatable {
  /// The agent the session runs: its logo, “Claude Code · Opus 5.5”, and its state.
  struct Current: Equatable {
    let title: String
    let state: String
    let symbolName: String
  }

  /// One agent of “Switch To”: its logo, its name, and its models.
  struct Section: Equatable {
    let name: String
    let symbolName: String
    let choices: [Choice]
  }

  struct Choice: Equatable {
    let title: String
    let isCurrent: Bool
    let target: AgentTarget
  }

  let current: Current
  /// Newest first; empty when the session never switched.
  let history: [AgentHistoryPresentation.Entry]
  let canSwitch: Bool
  let sections: [Section]

  /// The logo of an agent this build does not know.
  static let unknownAgentSymbol = "cpu"

  @MainActor
  init(
    session: WorkSession, names: AgentLabels, choices: AgentSwitchChoices?, state: String,
    canSwitch: Bool
  ) {
    let history = AgentHistoryPresentation(session: session, names: names)
    current = Current(
      title: session.agent.map { names.label($0) }
        ?? String(localized: "No agent recorded", bundle: .module),
      state: Self.withoutFinalStop(state),
      symbolName: session.agent.flatMap { choices?.agent($0.providerID)?.descriptor.symbolName }
        ?? Self.unknownAgentSymbol)
    self.history = history.hasChanges ? history.entries : []
    self.canSwitch = canSwitch
    sections = (choices?.offered ?? []).map { agent in
      Section(
        name: agent.name, symbolName: agent.descriptor.symbolName,
        choices: (choices?.choices(for: agent, current: session.agent) ?? []).map { choice in
          Choice(
            title: choice.modelName
              ?? String(localized: "Default model of the agent", bundle: .module),
            isCurrent: choice.isCurrent, target: choice.target)
        })
    }
  }

  /// “Ready to resume”: a subtitle is no sentence, and ends without a stop. An ellipsis is kept.
  static func withoutFinalStop(_ text: String) -> String {
    guard text.hasSuffix("."), !text.hasSuffix("..") else { return text }
    return String(text.dropLast())
  }
}

/// The agent's menu, as AppKit draws it (#575): a real `NSMenu`, so that its submenus open where
/// macOS opens them, with what a SwiftUI menu cannot give an item — a title in bold, an image on
/// a section's header, a line read in full rather than greyed out.
@MainActor
enum AgentMenu {
  /// A menu that keeps what its items act on: an item holds its target weakly.
  final class Menu: NSMenu {
    var actions: Actions?
  }

  final class Actions: NSObject {
    let open: (AgentTarget?) -> Void

    init(open: @escaping (AgentTarget?) -> Void) {
      self.open = open
    }

    @objc func choose(_ item: NSMenuItem) {
      open(item.representedObject as? AgentTarget)
    }
  }

  /// `open` is given the agent and model chosen, or `nil` for “Other Settings…”.
  static func make(_ content: AgentMenuContent, open: @escaping (AgentTarget?) -> Void) -> Menu {
    let actions = Actions(open: open)
    let menu = Menu()
    menu.actions = actions
    // Enabled or not as said here: a line of the history acts on nothing, and reads in full.
    menu.autoenablesItems = false
    menu.addItem(currentItem(content))
    menu.addItem(.separator())

    let switchTo = NSMenuItem(
      title: String(
        localized: "Switch To", bundle: .module,
        comment: "Opens the agents and models to switch to."),
      action: nil, keyEquivalent: "")
    switchTo.submenu = switchMenu(content, actions: actions)
    switchTo.isEnabled = content.canSwitch
    menu.addItem(switchTo)
    return menu
  }

  /// The logo, the agent in bold and its state under it; the history as its submenu.
  private static func currentItem(_ content: AgentMenuContent) -> NSMenuItem {
    let item = NSMenuItem(title: content.current.title, action: nil, keyEquivalent: "")
    item.attributedTitle = NSAttributedString(
      string: content.current.title,
      attributes: [
        .font: NSFontManager.shared.convert(NSFont.menuFont(ofSize: 0), toHaveTrait: .boldFontMask)
      ])
    setSubtitle(content.current.state, of: item)
    setImage(logo(content.current.symbolName), of: item)
    item.setAccessibilityLabel("\(content.current.title), \(content.current.state)")
    if !content.history.isEmpty {
      let history = NSMenu()
      history.autoenablesItems = false
      for entry in content.history {
        let line = NSMenuItem(
          title: entry.failed ? "⚠︎ \(entry.title)" : entry.title, action: nil, keyEquivalent: "")
        setSubtitle(entry.detail, of: line)
        line.setAccessibilityLabel(entry.spoken)
        history.addItem(line)
      }
      item.submenu = history
    }
    return item
  }

  /// Each agent under its logo and name, its models, the one the session runs checked; then the
  /// sheet, set on nothing.
  private static func switchMenu(_ content: AgentMenuContent, actions: Actions) -> NSMenu {
    let menu = NSMenu()
    menu.autoenablesItems = false
    for section in content.sections {
      let header = NSMenuItem.sectionHeader(title: section.name)
      setImage(logo(section.symbolName), of: header)
      menu.addItem(header)
      for choice in section.choices {
        let item = NSMenuItem(
          title: choice.title, action: #selector(Actions.choose(_:)), keyEquivalent: "")
        item.target = actions
        item.representedObject = choice.target
        item.state = choice.isCurrent ? .on : .off
        // The one it runs is no switch.
        item.isEnabled = !choice.isCurrent
        menu.addItem(item)
      }
    }
    menu.addItem(.separator())
    let other = NSMenuItem(
      title: String(
        localized: "Other Settings…", bundle: .module,
        comment: "Opens the Switch Agent sheet with nothing chosen yet."),
      action: #selector(Actions.choose(_:)), keyEquivalent: "")
    other.target = actions
    menu.addItem(other)
    return menu
  }

  /// An agent's logo, at the size of a menu's text, drawn in the menu's colours.
  static func logo(_ symbolName: String) -> NSImage? {
    let image =
      NSImage(systemSymbolName: symbolName, accessibilityDescription: nil)
      ?? NSImage(systemSymbolName: AgentMenuContent.unknownAgentSymbol, accessibilityDescription: nil)
    let sized = image?.withSymbolConfiguration(
      NSImage.SymbolConfiguration(pointSize: NSFont.systemFontSize, weight: .regular))
    sized?.isTemplate = true
    return sized
  }

  /// macOS 27 hides the images of menu items unless asked: a logo is what tells the agents apart.
  private static func setImage(_ image: NSImage?, of item: NSMenuItem) {
    item.image = image
    if #available(macOS 27, *) {
      item.preferredImageVisibility = .visible
    }
  }

  /// A second line in the menu's secondary style; before macOS 14.4, after the title.
  private static func setSubtitle(_ subtitle: String, of item: NSMenuItem) {
    guard !subtitle.isEmpty else { return }
    if #available(macOS 14.4, *) {
      item.subtitle = subtitle
    } else {
      let title = NSMutableAttributedString(
        attributedString: item.attributedTitle ?? NSAttributedString(string: item.title))
      title.append(
        NSAttributedString(
          string: "\n\(subtitle)",
          attributes: [.font: NSFont.menuFont(ofSize: NSFont.smallSystemFontSize)]))
      item.attributedTitle = title
    }
  }
}

import SwiftUI
import VibeApplication
import VibeDomain

/// The pages of the settings window (#313), as its sidebar lists them.
///
/// Each agent and each endpoint has a page of its own, and two pages are reached from another
/// rather than from the sidebar: the avatars from the requests, the resolvers from the tickets.
public enum SettingsPage: Hashable, Sendable {
  case general
  /// The conversation view of #38: its theme, its fonts, what it unfolds.
  case conversation
  /// The symbols and colours a session may be given (#199).
  case sessionAppearance
  /// How the requests of background sessions are signalled (#40), and the floating panel (#41).
  case requests
  /// The avatars of the floating panel (#154), reached from the requests.
  case avatars
  /// An agent whose activity can be tracked (#45).
  case agent(AgentProviderID)
  /// A model server a session can run on (#107).
  case endpoint(EndpointID)
  /// A new endpoint, started from a known server.
  case newEndpoint
  /// The session's web view (#69): what agents may do there, and where links go.
  case webView
  /// The prompt templates: a list, an editor and a preview.
  case templates
  /// The titles of the tickets a new session names (#89).
  case tickets
  /// The resolvers that recognise a ticket's address, reached from the tickets.
  case ticketResolvers
  /// Full Disk Access (#76), and the data the application keeps on this Mac.
  case privacy
  /// Whether and how the application updates itself, and on which channel (#92).
  case updates

  /// The page this one is reached from, and goes back to; `nil` for a page of the sidebar.
  var parent: SettingsPage? {
    switch self {
    case .avatars: .requests
    case .ticketResolvers: .tickets
    default: nil
    }
  }

  /// The page of the sidebar this one belongs to: itself, or its parent.
  var sidebarPage: SettingsPage { parent ?? self }

  /// The least width the page needs beside the sidebar. The window widens to it when the page
  /// is shown, and comes back when it is left.
  var detailWidth: CGFloat {
    switch self {
    // A list, an editor and a preview side by side.
    case .templates: 1_150
    // The form and the preview beside it.
    case .conversation: 925
    // The library's list and the avatar's workshop.
    case .avatars: 900
    // The list of the resolvers, their editor, and the test under them.
    case .ticketResolvers: 860
    default: Self.standardDetailWidth
    }
  }

  /// The width of a page that is a single form.
  nonisolated static let standardDetailWidth: CGFloat = 620

  /// The page's name, in the sidebar and in the window's title. An agent's or an endpoint's page
  /// is named after them, by the sidebar.
  var title: LocalizedStringResource {
    switch self {
    case .general:
      LocalizedStringResource("General", bundle: .module, comment: "A page of the Settings window.")
    case .conversation:
      LocalizedStringResource(
        "Conversation", bundle: .module, comment: "A page of the Settings window.")
    case .sessionAppearance:
      LocalizedStringResource(
        "Badges", bundle: .module,
        comment: "A page of the Settings window: the symbols and colours sessions may be given.")
    case .requests:
      LocalizedStringResource(
        "Notifications", bundle: .module,
        comment: "A page of the Settings window: how the requests of the agents are signalled.")
    case .avatars:
      LocalizedStringResource(
        "Avatars", bundle: .module,
        comment: "A page of Settings › Requests: the avatars of the floating panel.")
    case .agent:
      LocalizedStringResource(
        "Agent", bundle: .module, comment: "A page of the Settings window: an agent.")
    case .endpoint:
      LocalizedStringResource(
        "Endpoint", bundle: .module, comment: "A page of the Settings window: a model server.")
    case .newEndpoint:
      LocalizedStringResource(
        "New Endpoint", bundle: .module, comment: "A page of the Settings window.")
    case .webView:
      LocalizedStringResource(
        "Web View", bundle: .module, comment: "A page of the Settings window.")
    case .templates:
      LocalizedStringResource(
        "Templates", bundle: .module, comment: "A page of the Settings window.")
    case .tickets:
      LocalizedStringResource("Tickets", bundle: .module, comment: "A page of the Settings window.")
    case .ticketResolvers:
      LocalizedStringResource(
        "Resolvers", bundle: .module,
        comment: "A page of Settings › Tickets: what recognises a ticket's address.")
    case .privacy:
      LocalizedStringResource("Privacy", bundle: .module, comment: "A page of the Settings window.")
    case .updates:
      LocalizedStringResource("Updates", bundle: .module, comment: "A page of the Settings window.")
    }
  }

  /// The symbol of the page's icon in the sidebar.
  var symbolName: String {
    switch self {
    case .general: "gearshape.fill"
    case .conversation: "bubble.left.and.text.bubble.right.fill"
    case .sessionAppearance: "paintpalette.fill"
    case .requests, .avatars: "bell.badge.fill"
    case .agent: "sparkles"
    case .endpoint: "server.rack"
    case .newEndpoint: "plus"
    case .webView: "globe"
    case .templates: "text.badge.plus"
    case .tickets, .ticketResolvers: "ticket.fill"
    case .privacy: "hand.raised.fill"
    case .updates: "arrow.down.circle.fill"
    }
  }

  /// The colour of the square behind the symbol, as System Settings draws its own.
  var tint: Color {
    switch self {
    case .general, .updates: .gray
    case .conversation: .blue
    case .sessionAppearance: .pink
    case .requests, .avatars: .red
    case .agent: .orange
    case .endpoint: .indigo
    case .newEndpoint: .secondary
    case .webView: .cyan
    case .templates: .purple
    case .tickets, .ticketResolvers: .orange
    case .privacy: .blue
    }
  }

  /// What the search of the sidebar finds the page by, besides its name: the settings it holds,
  /// in the words the page shows them with.
  var keywords: [LocalizedStringResource] {
    switch self {
    case .general:
      [
        LocalizedStringResource("Open sessions in", bundle: .module),
        LocalizedStringResource(
          "Ask before closing or archiving a session where work is running", bundle: .module),
        LocalizedStringResource("When quitting with agents running", bundle: .module),
        LocalizedStringResource("Summarize sessions automatically", bundle: .module),
        LocalizedStringResource("Keep the history of side terminals", bundle: .module),
        LocalizedStringResource("Open changed files with", bundle: .module),
      ]
    case .conversation:
      [
        LocalizedStringResource("Theme", bundle: .module),
        LocalizedStringResource("Message font", bundle: .module),
        LocalizedStringResource("Code font", bundle: .module),
        LocalizedStringResource("Text size", bundle: .module),
        LocalizedStringResource("Show reasoning rows", bundle: .module),
        LocalizedStringResource("Line numbers in diffs", bundle: .module),
      ]
    case .sessionAppearance:
      [
        LocalizedStringResource(
          "Symbols", bundle: .module, comment: "A section of the Badges settings."),
        LocalizedStringResource(
          "Colours", bundle: .module, comment: "A section of the Badges settings."),
      ]
    case .requests:
      [
        LocalizedStringResource("Show the number of requests on the Dock icon", bundle: .module),
        LocalizedStringResource("Unfold the palette when a request arrives", bundle: .module),
        LocalizedStringResource("Notify me of requests and replies", bundle: .module),
        LocalizedStringResource("Show requests above other applications", bundle: .module),
        LocalizedStringResource(
          "Avatar", bundle: .module, comment: "The avatar of the floating panel."),
      ]
    case .webView:
      [
        LocalizedStringResource("Give agents the web view", bundle: .module),
        LocalizedStringResource("Open links", bundle: .module),
        LocalizedStringResource("Always allowed sites", bundle: .module),
        LocalizedStringResource("Browsing data", bundle: .module),
      ]
    case .tickets:
      [
        LocalizedStringResource("Insert ticket titles in the notes", bundle: .module),
        LocalizedStringResource("Line format", bundle: .module),
        LocalizedStringResource(
          "Resolvers", bundle: .module,
          comment: "A page of Settings › Tickets: what recognises a ticket's address."),
      ]
    case .privacy:
      [
        LocalizedStringResource("Full Disk Access", bundle: .module),
        LocalizedStringResource("Track agent usage", bundle: .module),
        LocalizedStringResource("Diagnostics", bundle: .module),
      ]
    case .updates:
      [
        LocalizedStringResource("Check for updates automatically", bundle: .module),
        LocalizedStringResource(
          "Channel", bundle: .module, comment: "Which versions are offered as updates."),
      ]
    case .agent:
      [
        LocalizedStringResource(
          "Agents", bundle: .module, comment: "A group of the Settings window's sidebar.")
      ]
    case .endpoint, .newEndpoint:
      [
        LocalizedStringResource(
          "Endpoints", bundle: .module, comment: "A group of the Settings window's sidebar.")
      ]
    case .avatars, .templates, .ticketResolvers:
      []
    }
  }

  /// Whether the page answers the search `query`: by its name, or by one of its settings.
  ///
  /// `name` is the page's name as the sidebar shows it, which for an agent or an endpoint is
  /// theirs. Case and accents are ignored, in the language the window speaks.
  func matches(_ query: String, name: String, locale: Locale) -> Bool {
    let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !query.isEmpty else { return true }
    return ([name] + keywords.map { Self.string($0, locale: locale) }).contains {
      $0.range(of: query, options: [.caseInsensitive, .diacriticInsensitive], locale: locale)
        != nil
    }
  }

  /// `resource` in the language of `locale`.
  static func string(_ resource: LocalizedStringResource, locale: Locale) -> String {
    var resource = resource
    resource.locale = locale
    return String(localized: resource)
  }
}

/// The square icon of a page, a white symbol on a colour, as the sidebar of System Settings.
struct SettingsPageIcon: View {
  let symbolName: String
  let tint: Color

  var body: some View {
    Image(systemName: symbolName)
      .font(.system(size: 11, weight: .semibold))
      .foregroundStyle(.white)
      .frame(width: 20, height: 20)
      .background(RoundedRectangle(cornerRadius: 5, style: .continuous).fill(tint.gradient))
      .accessibilityHidden(true)
  }
}

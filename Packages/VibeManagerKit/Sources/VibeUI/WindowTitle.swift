import Foundation

/// What the window's header says (#159): the application, then the session on screen.
///
/// One value for every place that says it — the window's title, which the Window menu, Mission
/// Control and ⌘` read, the header drawn in the toolbar, its help tag and VoiceOver — so that they
/// can never disagree.
public struct WindowTitle: Equatable, Sendable {
  public var applicationName: String
  /// The session on screen, on one line; `nil` when there is none.
  public var sessionName: String?

  public init(applicationName: String, sessionName: String?) {
    self.applicationName = applicationName
    self.sessionName = sessionName.flatMap(Self.singleLine)
  }

  /// The window's title: "Vibe Manager › <session>", or the application alone.
  public var full: String {
    guard let sessionName else { return applicationName }
    return String(
      localized: "\(applicationName) › \(sessionName)", bundle: .module,
      comment: "The window's title: the application's name, then the session on screen.")
  }

  /// What VoiceOver says for the header, without the "›" it would read out as a quotation mark.
  public var spoken: String {
    guard let sessionName else { return applicationName }
    return String(
      localized: "\(applicationName), \(sessionName)", bundle: .module,
      comment: "VoiceOver's reading of the window's header: the application, then the session.")
  }

  /// A name typed with a line break would push the title onto two lines; a name of nothing but
  /// spaces says nothing, and the application alone is shown.
  private static func singleLine(_ name: String) -> String? {
    let line = name.components(separatedBy: .newlines).joined(separator: " ")
      .trimmingCharacters(in: .whitespaces)
    return line.isEmpty ? nil : line
  }
}

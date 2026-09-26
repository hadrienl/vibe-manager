import Foundation
import VibeDomain

/// How a session is shown: its conversation, read from the transcripts, or its raw terminal.
public enum SessionPresentation: String, Codable, Hashable, Sendable {
  case conversation
  case terminal
}

/// Everything the Conversation tab of the settings holds (#38).
///
/// Interface preferences of this Mac, kept in the user defaults like the layout. Every field is
/// read with a fallback, so that a preference written by a later build — or edited by hand —
/// never costs the others.
public struct ConversationAppearance: Codable, Hashable, Sendable {
  public enum Accent: String, Codable, CaseIterable, Hashable, Sendable {
    case theme, blue, purple, pink, orange, green, graphite, custom
  }

  public enum TextSize: String, Codable, CaseIterable, Hashable, Sendable {
    case small, medium, large, extraLarge

    public var pointSize: Double {
      switch self {
      case .small: return 13
      case .medium: return 14.5
      case .large: return 16
      case .extraLarge: return 18
      }
    }

    public var larger: TextSize {
      Self.allCases.first { $0.pointSize > pointSize } ?? self
    }

    public var smaller: TextSize {
      Self.allCases.last { $0.pointSize < pointSize } ?? self
    }
  }

  public enum Density: String, Codable, CaseIterable, Hashable, Sendable {
    case compact, comfortable
  }

  public enum UserMessageStyle: String, Codable, CaseIterable, Hashable, Sendable {
    case bubbles, lines
  }

  public var defaultPresentation: SessionPresentation
  /// When on, the dark theme applies while macOS is dark, the light one otherwise.
  public var followsSystemAppearance: Bool
  public var lightTheme: String
  public var darkTheme: String
  public var accent: Accent
  /// The colour chosen with the colour picker, as `#RRGGBB`, used when `accent` is `.custom`.
  public var customAccent: String?
  /// A font family, `nil` for the theme's own.
  public var messageFont: String?
  public var codeFont: String?
  public var textSize: TextSize
  public var density: Density
  public var userMessageStyle: UserMessageStyle
  public var groupsToolCalls: Bool
  public var expandsFailures: Bool
  public var expandsEdits: Bool
  public var showsReasoning: Bool
  public var wrapsCode: Bool
  public var showsDiffLineNumbers: Bool

  public static let defaultLightTheme = "system-light"
  public static let defaultDarkTheme = "system-dark"

  public init(
    defaultPresentation: SessionPresentation = .conversation,
    followsSystemAppearance: Bool = true,
    lightTheme: String = ConversationAppearance.defaultLightTheme,
    darkTheme: String = ConversationAppearance.defaultDarkTheme,
    accent: Accent = .theme,
    customAccent: String? = nil,
    messageFont: String? = nil,
    codeFont: String? = nil,
    textSize: TextSize = .medium,
    density: Density = .comfortable,
    userMessageStyle: UserMessageStyle = .bubbles,
    groupsToolCalls: Bool = true,
    expandsFailures: Bool = true,
    expandsEdits: Bool = false,
    showsReasoning: Bool = true,
    wrapsCode: Bool = false,
    showsDiffLineNumbers: Bool = true
  ) {
    self.defaultPresentation = defaultPresentation
    self.followsSystemAppearance = followsSystemAppearance
    self.lightTheme = lightTheme
    self.darkTheme = darkTheme
    self.accent = accent
    self.customAccent = customAccent
    self.messageFont = messageFont
    self.codeFont = codeFont
    self.textSize = textSize
    self.density = density
    self.userMessageStyle = userMessageStyle
    self.groupsToolCalls = groupsToolCalls
    self.expandsFailures = expandsFailures
    self.expandsEdits = expandsEdits
    self.showsReasoning = showsReasoning
    self.wrapsCode = wrapsCode
    self.showsDiffLineNumbers = showsDiffLineNumbers
  }

  public init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    let fallback = ConversationAppearance()
    func value<T: Decodable>(_ key: CodingKeys, _ current: T) -> T {
      (try? container.decodeIfPresent(T.self, forKey: key)) ?? current
    }
    self.init(
      defaultPresentation: value(.defaultPresentation, fallback.defaultPresentation),
      followsSystemAppearance: value(.followsSystemAppearance, fallback.followsSystemAppearance),
      lightTheme: value(.lightTheme, fallback.lightTheme),
      darkTheme: value(.darkTheme, fallback.darkTheme),
      accent: value(.accent, fallback.accent),
      customAccent: (try? container.decodeIfPresent(String.self, forKey: .customAccent)) ?? nil,
      messageFont: (try? container.decodeIfPresent(String.self, forKey: .messageFont)) ?? nil,
      codeFont: (try? container.decodeIfPresent(String.self, forKey: .codeFont)) ?? nil,
      textSize: value(.textSize, fallback.textSize),
      density: value(.density, fallback.density),
      userMessageStyle: value(.userMessageStyle, fallback.userMessageStyle),
      groupsToolCalls: value(.groupsToolCalls, fallback.groupsToolCalls),
      expandsFailures: value(.expandsFailures, fallback.expandsFailures),
      expandsEdits: value(.expandsEdits, fallback.expandsEdits),
      showsReasoning: value(.showsReasoning, fallback.showsReasoning),
      wrapsCode: value(.wrapsCode, fallback.wrapsCode),
      showsDiffLineNumbers: value(.showsDiffLineNumbers, fallback.showsDiffLineNumbers)
    )
  }

  /// The theme in force for the system's current appearance.
  public func themeIdentifier(isDark: Bool) -> String {
    followsSystemAppearance && isDark ? darkTheme : lightTheme
  }
}

/// Where the Conversation settings are kept.
@MainActor
public protocol ConversationAppearanceStore: AnyObject {
  var appearance: ConversationAppearance { get set }
}

/// Kept for this run only. What a workspace assembled without the system around it uses.
@MainActor
public final class InMemoryConversationAppearanceStore: ConversationAppearanceStore {
  public var appearance: ConversationAppearance

  public init(appearance: ConversationAppearance = ConversationAppearance()) {
    self.appearance = appearance
  }
}

import SwiftUI
import VibeApplication

/// The skills and commands of the session's agent, above the composer while a `/` is typed first
/// (#219): skills then commands, each with its name, where it comes from and what it does.
///
/// The keyboard stays in the composer: ↑ and ↓ move the selection there, ⇥ and ↩ insert, Escape
/// closes. A click inserts too.
public struct CommandSuggestionList: View {
  let commands: ComposerCommands
  /// Puts the command clicked in the text, and the keyboard back in it.
  let insert: (AgentCommand) -> Void
  @Environment(\.conversationTheme) private var theme
  @State private var contentHeight: CGFloat = 0

  /// About seven entries and a half: the next one shows there is more.
  private static let maximumHeight: CGFloat = 380

  public init(commands: ComposerCommands, insert: @escaping (AgentCommand) -> Void) {
    self.commands = commands
    self.insert = insert
  }

  public var body: some View {
    let matches = commands.suggestions ?? []
    VStack(alignment: .leading, spacing: 0) {
      if matches.isEmpty {
        Text("No skill matches", bundle: .module)
          .font(theme.interfaceFont(size: 12.5))
          .foregroundStyle(theme.secondaryText.color)
          .padding(.horizontal, 14)
          .padding(.vertical, 12)
      } else {
        ScrollViewReader { proxy in
          ScrollView {
            rows(matches)
              .onGeometryChange(for: CGFloat.self, of: \.size.height) { contentHeight = $0 }
          }
          .frame(height: min(contentHeight, Self.maximumHeight))
          .onChange(of: commands.selectedIndex) { _, index in
            proxy.scrollTo(index)
            announce(matches, at: index)
          }
        }
      }
      Rectangle().fill(theme.border.color).frame(height: 1)
      Text("↑↓ navigate · ⇥ or ↩ insert · Esc close", bundle: .module)
        .font(theme.interfaceFont(size: 11))
        .foregroundStyle(theme.secondaryText.color)
        .padding(.horizontal, 14)
        .padding(.vertical, 7)
        .accessibilityHidden(true)
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(theme.raised.color, in: RoundedRectangle(cornerRadius: 12))
    .overlay(RoundedRectangle(cornerRadius: 12).stroke(theme.border.color))
    .shadow(color: .black.opacity(theme.isDark ? 0.35 : 0.12), radius: 10, y: 3)
    // As tall as its entries, whatever the view it stands above proposes.
    .fixedSize(horizontal: false, vertical: true)
    .accessibilityElement(children: .contain)
    .accessibilityLabel(Text("\(matches.count) skills and commands", bundle: .module))
    .onAppear { announceCount(matches.count) }
  }

  private func rows(_ matches: [AgentCommandMatch]) -> some View {
    VStack(alignment: .leading, spacing: 0) {
      ForEach(Array(matches.enumerated()), id: \.element.id) { index, match in
        if index == 0 || matches[index - 1].command.kind != match.command.kind {
          header(match.command.kind)
        }
        CommandSuggestionRow(match: match, isSelected: index == commands.selectedIndex)
          .id(index)
          .contentShape(Rectangle())
          .onTapGesture { insert(match.command) }
          .accessibilityAddTraits(.isButton)
          .accessibilityAction { insert(match.command) }
      }
    }
    .padding(.vertical, 4)
  }

  private func header(_ kind: AgentCommand.Kind) -> some View {
    Group {
      switch kind {
      case .skill: Text("Skills", bundle: .module)
      case .command: Text("Commands", bundle: .module)
      }
    }
    .font(theme.interfaceFont(size: 11, weight: .semibold))
    .foregroundStyle(theme.secondaryText.color)
    .textCase(.uppercase)
    .padding(.horizontal, 14)
    .padding(.top, 8)
    .padding(.bottom, 4)
    .accessibilityAddTraits(.isHeader)
  }

  /// The keyboard stays in the composer: VoiceOver is told which entry the arrows reached.
  private func announce(_ matches: [AgentCommandMatch], at index: Int) {
    guard matches.indices.contains(index) else { return }
    AccessibilityNotification.Announcement(
      CommandSuggestionRow.spokenLabel(matches[index].command)
    ).post()
  }

  private func announceCount(_ count: Int) {
    AccessibilityNotification.Announcement(
      String(localized: "\(count) skills and commands", bundle: .module)
    ).post()
  }
}

/// One skill or command: its icon, its name with what the query found, where it comes from, and
/// what it does on two lines at most — the whole text in its help tag.
struct CommandSuggestionRow: View {
  let match: AgentCommandMatch
  let isSelected: Bool
  @Environment(\.conversationTheme) private var theme

  var body: some View {
    let command = match.command
    HStack(alignment: .top, spacing: 10) {
      Image(systemName: command.kind == .skill ? "sparkles" : "command")
        .font(.system(size: 12, weight: .medium))
        .foregroundStyle(isSelected ? theme.accent.color : theme.secondaryText.color)
        .frame(width: 18, height: 18)
      VStack(alignment: .leading, spacing: 2) {
        HStack(spacing: 8) {
          Text(name)
            .font(theme.codeFont(size: 12.5))
            .foregroundStyle(theme.text.color)
            .lineLimit(1)
            .truncationMode(.middle)
            .layoutPriority(1)
          if let origin = Self.originLabel(command.origin) {
            Text(origin)
              .font(theme.interfaceFont(size: 10.5))
              .foregroundStyle(theme.secondaryText.color)
              .lineLimit(1)
              .truncationMode(.middle)
              .padding(.horizontal, 6)
              .padding(.vertical, 1)
              .background(theme.surface.color, in: Capsule())
              .overlay(Capsule().stroke(theme.border.color))
          }
        }
        if !command.description.isEmpty {
          Text(description)
            .font(theme.interfaceFont(size: 12))
            .foregroundStyle(theme.secondaryText.color)
            .lineLimit(2)
            .truncationMode(.tail)
            .fixedSize(horizontal: false, vertical: true)
        }
      }
      Spacer(minLength: 0)
    }
    .padding(.horizontal, 10)
    .padding(.vertical, 6)
    .background(
      isSelected ? theme.accent.color.opacity(theme.isDark ? 0.24 : 0.13) : .clear,
      in: RoundedRectangle(cornerRadius: 8)
    )
    .padding(.horizontal, 4)
    .help(command.description)
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(Text(verbatim: Self.spokenLabel(command)))
    .accessibilityAddTraits(isSelected ? .isSelected : [])
  }

  /// `/name`, what the query found underlined.
  private var name: AttributedString {
    let command = match.command
    var text = AttributedString(String(command.trigger))
    text += Self.underlining(command.name, match.nameRanges, color: theme.accent.color)
    return text
  }

  private var description: AttributedString {
    Self.underlining(
      match.command.description, match.descriptionRanges, color: theme.text.color)
  }

  private static func underlining(_ string: String, _ ranges: [Range<Int>], color: Color)
    -> AttributedString
  {
    var text = AttributedString(string)
    for range in ranges {
      let characters = text.characters
      guard range.upperBound <= characters.count else { continue }
      let start = characters.index(characters.startIndex, offsetBy: range.lowerBound)
      let end = characters.index(characters.startIndex, offsetBy: range.upperBound)
      text[start..<end].underlineStyle = .single
      text[start..<end].foregroundColor = color
    }
    return text
  }

  static func originLabel(_ origin: AgentCommand.Origin?) -> String? {
    switch origin {
    case .project: return String(localized: "project", bundle: .module)
    case .user: return String(localized: "user", bundle: .module)
    case .plugin(let name): return name
    case .system: return String(localized: "system", bundle: .module)
    case .builtin: return String(localized: "built-in", bundle: .module)
    case nil: return nil
    }
  }

  /// « name, description, origin ».
  static func spokenLabel(_ command: AgentCommand) -> String {
    [command.invocation, command.description, originLabel(command.origin) ?? ""]
      .filter { !$0.isEmpty }.joined(separator: ", ")
  }
}

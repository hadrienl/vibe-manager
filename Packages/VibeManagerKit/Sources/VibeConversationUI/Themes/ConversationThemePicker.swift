import SwiftUI
import VibeApplication

/// The theme of one session's conversation (#274): the settings' — `nil` —, or one of the themes
/// built in or of the user's, drawn as the settings' cards are. Shared by the new session's draft,
/// the Change Theme popover and the template editor.
///
/// Each choice is the selection at once; what keeps it, or lets it go, is the caller's. The arrows
/// move the selection from card to card, Return calls `commit`, Escape `cancel`.
public struct ConversationThemePicker: View {
  private enum Option: Hashable {
    /// The identifier chosen, which names no theme any more.
    case missing(String)
    case settings
    case theme(String)

    var selection: String? {
      switch self {
      case .missing(let id), .theme(let id): id
      case .settings: nil
      }
    }
  }

  @Binding private var selection: String?
  private let themes: ConversationThemesModel
  private let appearance: ConversationAppearance
  private let nilTitle: Text
  private let commit: (() -> Void)?
  private let cancel: (() -> Void)?
  @Environment(\.colorScheme) private var colorScheme
  @Environment(\.colorSchemeContrast) private var contrast
  @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
  @FocusState private var isFocused: Bool
  /// The selection when the picker appeared: what Escape gives back.
  @State private var initial: String??
  /// A theme chosen before that is no longer there: its card stays while the picker is open, so
  /// that the arrows can come back to it.
  @State private var missingID: String?

  private static let columns = 3

  /// - Parameter nilTitle: what the first card, `nil`, is called: following the settings, for a
  ///   session; giving none, for a template.
  public init(
    selection: Binding<String?>, themes: ConversationThemesModel,
    appearance: ConversationAppearance, nilTitle: Text,
    commit: (() -> Void)? = nil, cancel: (() -> Void)? = nil
  ) {
    _selection = selection
    self.themes = themes
    self.appearance = appearance
    self.nilTitle = nilTitle
    self.commit = commit
    self.cancel = cancel
  }

  private var options: [Option] {
    var options: [Option] = []
    if let missing = missingID ?? selection.flatMap({ themes.theme($0) == nil ? $0 : nil }) {
      options.append(.missing(missing))
    }
    options.append(.settings)
    options += themes.offered.map { .theme($0.id) }
    return options
  }

  private var selected: Option {
    guard let selection else { return .settings }
    return themes.theme(selection) == nil ? .missing(selection) : .theme(selection)
  }

  public var body: some View {
    LazyVGrid(
      columns: Array(repeating: GridItem(.fixed(104), spacing: 10), count: Self.columns),
      spacing: 10
    ) {
      ForEach(options, id: \.self) { option in
        card(option)
      }
    }
    .focusable()
    .focusEffectDisabled()
    .focused($isFocused)
    .onAppear {
      isFocused = true
      initial = .some(selection)
      missingID = selection.flatMap { themes.theme($0) == nil ? $0 : nil }
    }
    .onKeyPress(keys: [.leftArrow, .rightArrow, .upArrow, .downArrow]) { press in
      move(by: Self.step(for: press.key))
      return .handled
    }
    .onKeyPress(.return) {
      guard let commit else { return .ignored }
      commit()
      return .handled
    }
    .onExitCommand {
      if let initial { selection = initial }
      cancel?()
    }
    .accessibilityElement(children: .contain)
    .accessibilityLabel(Text("Conversation Theme", bundle: .module))
  }

  private static func step(for key: KeyEquivalent) -> Int {
    switch key {
    case .leftArrow: -1
    case .rightArrow: 1
    case .upArrow: -columns
    default: columns
    }
  }

  private func move(by step: Int) {
    let options = options
    guard let index = options.firstIndex(of: selected) else { return }
    let next = min(max(index + step, 0), options.count - 1)
    selection = options[next].selection
  }

  @ViewBuilder
  private func card(_ option: Option) -> some View {
    let isCurrent = option == selected
    Button {
      selection = option.selection
    } label: {
      switch option {
      case .missing:
        MissingThemeCard(isCurrent: isCurrent)
      case .settings:
        ThemeCard(
          theme: settingsTheme, isCurrent: isCurrent, isOther: false, title: nilTitle)
      case .theme(let id):
        if let theme = themes.theme(id) {
          ThemeCard(theme: theme.applying(appearance), isCurrent: isCurrent, isOther: false)
        }
      }
    }
    .buttonStyle(.plain)
    .accessibilityLabel(label(option))
    .accessibilityAddTraits(isCurrent ? .isSelected : [])
    .help(label(option))
  }

  /// What the conversation is drawn with when it follows the settings, now.
  private var settingsTheme: ConversationTheme {
    themes.displayed(
      appearance, isDark: colorScheme == .dark, increasedContrast: contrast == .increased,
      reducedTransparency: reduceTransparency)
  }

  private func label(_ option: Option) -> Text {
    switch option {
    case .missing:
      Text("Theme Not Found", bundle: .module)
    case .settings:
      Text(
        "\(nilTitle), \(settingsTheme.displayName) now", bundle: .module,
        comment: "VoiceOver: the card that follows the settings, and the theme they give now.")
    case .theme(let id):
      if let theme = themes.theme(id), theme.isPersonal {
        Text("\(theme.displayName), a theme of yours", bundle: .module)
      } else {
        Text(verbatim: themes.theme(id)?.displayName ?? id)
      }
    }
  }
}

/// The card of a theme chosen that is no longer there: deleted, or its file unreadable.
private struct MissingThemeCard: View {
  let isCurrent: Bool

  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      Image(systemName: "questionmark.square.dashed")
        .font(.title2)
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity, minHeight: 56)
        .overlay(
          RoundedRectangle(cornerRadius: 6)
            .stroke(Color.secondary.opacity(0.5), style: StrokeStyle(lineWidth: 1, dash: [4, 3])))
      Text("Theme Not Found", bundle: .module)
        .font(.caption.weight(.semibold))
        .foregroundStyle(.orange)
        .lineLimit(1)
    }
    .padding(6)
    .background(
      RoundedRectangle(cornerRadius: 9)
        .stroke(
          isCurrent ? Color.accentColor : Color.secondary.opacity(0.25),
          lineWidth: isCurrent ? 2 : 1)
    )
    .contentShape(Rectangle())
  }
}

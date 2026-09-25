import AppKit
import SwiftUI
import VibeApplication
import VibeDomain

/// The fonts a Mac has, as the Conversation settings offer them.
public enum ConversationFonts {
  public static let messageSuggestions = [
    "SF Pro", "New York", "Iowan Old Style", "Charter", "Avenir Next", "Helvetica Neue",
  ]
  public static let codeSuggestions = ["SF Mono", "Menlo", "Monaco"]

  @MainActor public static var installedFamilies: [String] {
    NSFontManager.shared.availableFontFamilies.sorted()
  }

  /// Families with a fixed-pitch face: the only ones offered for code.
  @MainActor public static var installedMonospacedFamilies: [String] {
    let names = NSFontManager.shared.availableFontNames(with: .fixedPitchFontMask) ?? []
    let families = Set(names.compactMap { NSFont(name: $0, size: 12)?.familyName })
    return families.sorted()
  }

  @MainActor public static func isInstalled(_ family: String) -> Bool {
    // The system's own families are not always listed under their marketing names.
    if ["SF Pro", "SF Mono", "New York"].contains(family) { return true }
    return NSFontManager.shared.availableFontFamilies.contains(family)
  }

  /// The appearance with every font that is no longer installed given back to the theme.
  @MainActor public static func installedOnly(_ appearance: ConversationAppearance)
    -> ConversationAppearance
  {
    var appearance = appearance
    if let font = appearance.messageFont, !isInstalled(font) { appearance.messageFont = nil }
    if let font = appearance.codeFont, !isInstalled(font) { appearance.codeFont = nil }
    return appearance
  }

  /// SwiftUI finds the system's families by their design, not by name.
  static func resolvedFamily(_ family: String?) -> String? {
    switch family {
    case "SF Pro": return nil
    case "SF Mono": return nil
    default: return family
    }
  }
}

/// Settings › Conversation (#38): every preference of the conversation view, in a tab of its own,
/// with a preview that follows each change.
public struct ConversationSettingsView: View {
  @Binding var appearance: ConversationAppearance
  @Environment(\.colorScheme) private var colorScheme
  @Environment(\.colorSchemeContrast) private var contrast

  public init(appearance: Binding<ConversationAppearance>) {
    _appearance = appearance
  }

  public var body: some View {
    HStack(alignment: .top, spacing: 0) {
      Form {
        Section {
          Picker(selection: $appearance.defaultPresentation) {
            Text("Conversation", bundle: .module).tag(SessionPresentation.conversation)
            Text("Terminal", bundle: .module).tag(SessionPresentation.terminal)
          } label: {
            Text("Open sessions in", bundle: .module)
          }
          .pickerStyle(.segmented)
          Text(
            "Each session can then be switched with ⌥⌘T, and keeps its choice.", bundle: .module
          )
          .font(.caption)
          .foregroundStyle(.secondary)
        }
        Section {
          Toggle(isOn: $appearance.followsSystemAppearance) {
            Text("Follow light and dark mode", bundle: .module)
          }
          themeGrid
          if appearance.followsSystemAppearance {
            Text(
              "In light mode: \(themeName(appearance.lightTheme)). In dark mode: \(themeName(appearance.darkTheme)). Choosing a theme gives it to the mode macOS is in.",
              bundle: .module
            )
            .font(.caption)
            .foregroundStyle(.secondary)
          }
        } header: {
          Text("Theme", bundle: .module)
        }
        Section {
          accentRow
          fontRow(
            title: Text("Message font", bundle: .module), selection: $appearance.messageFont,
            suggestions: ConversationFonts.messageSuggestions,
            all: ConversationFonts.installedFamilies, sample: "Voix ambiguë d’un cœur", code: false)
          fontRow(
            title: Text("Code font", bundle: .module), selection: $appearance.codeFont,
            suggestions: ConversationFonts.codeSuggestions,
            all: ConversationFonts.installedMonospacedFamilies, sample: "0O 1lI {} => !=",
            code: true)
          Picker(selection: $appearance.textSize) {
            Text("Small", bundle: .module).tag(ConversationAppearance.TextSize.small)
            Text("Medium", bundle: .module).tag(ConversationAppearance.TextSize.medium)
            Text("Large", bundle: .module).tag(ConversationAppearance.TextSize.large)
            Text("Extra Large", bundle: .module).tag(ConversationAppearance.TextSize.extraLarge)
          } label: {
            Text("Text size", bundle: .module)
          }
          Picker(selection: $appearance.density) {
            Text("Compact", bundle: .module).tag(ConversationAppearance.Density.compact)
            Text("Comfortable", bundle: .module).tag(ConversationAppearance.Density.comfortable)
          } label: {
            Text("Density", bundle: .module)
          }
          .pickerStyle(.segmented)
          Picker(selection: $appearance.userMessageStyle) {
            Text("Bubbles", bundle: .module).tag(ConversationAppearance.UserMessageStyle.bubbles)
            Text("Lines", bundle: .module).tag(ConversationAppearance.UserMessageStyle.lines)
          } label: {
            Text("Your messages", bundle: .module)
          }
          .pickerStyle(.segmented)
        } header: {
          Text("Display", bundle: .module)
        }
        Section {
          Toggle(isOn: $appearance.groupsToolCalls) {
            Text("Group consecutive calls of the same kind", bundle: .module)
          }
          Toggle(isOn: $appearance.expandsFailures) {
            Text("Unfold a failed call", bundle: .module)
          }
          Toggle(isOn: $appearance.expandsEdits) {
            Text("Unfold file edits", bundle: .module)
          }
          Toggle(isOn: $appearance.showsReasoning) {
            Text("Show reasoning rows", bundle: .module)
          }
          Toggle(isOn: $appearance.wrapsCode) {
            Text("Wrap lines in code blocks", bundle: .module)
          }
          Toggle(isOn: $appearance.showsDiffLineNumbers) {
            Text("Line numbers in diffs", bundle: .module)
          }
        } header: {
          Text("Technical details", bundle: .module)
        }
        Section {
          Button {
            appearance = ConversationAppearance()
          } label: {
            Text("Restore Defaults", bundle: .module)
          }
        }
      }
      .formStyle(.grouped)
      .frame(width: 520)

      Divider()

      VStack(alignment: .leading, spacing: 10) {
        Text("Preview", bundle: .module).font(.headline)
        ConversationPreview(theme: currentTheme, appearance: installedAppearance)
          .frame(width: 360, height: 420)
          .clipShape(RoundedRectangle(cornerRadius: 12))
          .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.secondary.opacity(0.3)))
        Text(
          "The theme applies to the conversation view of every session. The terminal keeps the colours the agent sends it.",
          bundle: .module
        )
        .font(.caption)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
      }
      .padding(20)
      .frame(width: 400)
    }
  }

  private var installedAppearance: ConversationAppearance {
    ConversationFonts.installedOnly(appearance)
  }

  private var currentTheme: ConversationTheme {
    ConversationTheme.resolve(
      installedAppearance, isDark: colorScheme == .dark, increasedContrast: contrast == .increased)
  }

  private func themeName(_ id: String) -> String {
    ConversationTheme.named(id).map { String(localized: $0.localizedName) } ?? id
  }

  private var themeGrid: some View {
    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: 3), spacing: 10)
    {
      ForEach(ConversationTheme.builtIn) { theme in
        let isLight = appearance.lightTheme == theme.id
        let isDark = appearance.followsSystemAppearance && appearance.darkTheme == theme.id
        let isCurrent =
          appearance.followsSystemAppearance && colorScheme == .dark ? isDark : isLight
        Button {
          if appearance.followsSystemAppearance, colorScheme == .dark {
            appearance.darkTheme = theme.id
          } else {
            appearance.lightTheme = theme.id
          }
        } label: {
          ThemeCard(theme: theme, isCurrent: isCurrent, isOther: !isCurrent && (isLight || isDark))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(theme.localizedName))
        .accessibilityAddTraits(isCurrent ? .isSelected : [])
      }
    }
  }

  private var accentRow: some View {
    LabeledContent {
      HStack(spacing: 8) {
        ForEach(ConversationAppearance.Accent.allCases, id: \.self) { accent in
          Button {
            appearance.accent = accent
          } label: {
            Circle()
              .fill(swatch(accent))
              .frame(width: 18, height: 18)
              .overlay(
                Circle().stroke(Color.accentColor, lineWidth: appearance.accent == accent ? 2 : 0)
                  .padding(-3))
          }
          .buttonStyle(.plain)
          .accessibilityLabel(Text(Self.accentName(accent)))
          .accessibilityAddTraits(appearance.accent == accent ? .isSelected : [])
        }
      }
    } label: {
      Text("Accent colour", bundle: .module)
    }
  }

  private func swatch(_ accent: ConversationAppearance.Accent) -> AnyShapeStyle {
    guard let colors = ConversationTheme.accentColors[accent] else {
      return AnyShapeStyle(
        AngularGradient(
          colors: [.blue, .orange, .green, .purple, .blue], center: .center))
    }
    return AnyShapeStyle((colorScheme == .dark ? colors.dark : colors.light).color)
  }

  static func accentName(_ accent: ConversationAppearance.Accent) -> LocalizedStringResource {
    switch accent {
    case .theme: return LocalizedStringResource("The theme's", bundle: .module)
    case .blue: return LocalizedStringResource("Blue", bundle: .module)
    case .purple: return LocalizedStringResource("Purple", bundle: .module)
    case .pink: return LocalizedStringResource("Pink", bundle: .module)
    case .orange: return LocalizedStringResource("Orange", bundle: .module)
    case .green: return LocalizedStringResource("Green", bundle: .module)
    case .graphite: return LocalizedStringResource("Graphite", bundle: .module)
    }
  }

  private func fontRow(
    title: Text, selection: Binding<String?>, suggestions: [String], all: [String], sample: String,
    code: Bool
  ) -> some View {
    LabeledContent {
      VStack(alignment: .trailing, spacing: 4) {
        HStack(spacing: 10) {
          Text(verbatim: sample)
            .font(sampleFont(selection.wrappedValue, code: code))
            .foregroundStyle(.secondary)
            .lineLimit(1)
          Menu {
            Button {
              selection.wrappedValue = nil
            } label: {
              Text("The theme's", bundle: .module)
            }
            Divider()
            ForEach(suggestions.filter(ConversationFonts.isInstalled), id: \.self) { family in
              Button(family) { selection.wrappedValue = family }
            }
            Divider()
            Menu {
              ForEach(all, id: \.self) { family in
                Button(family) { selection.wrappedValue = family }
              }
            } label: {
              Text("Other", bundle: .module)
            }
          } label: {
            if let family = selection.wrappedValue {
              Text(verbatim: family)
            } else {
              Text("The theme's", bundle: .module)
            }
          }
          .fixedSize()
        }
        if let family = selection.wrappedValue, !ConversationFonts.isInstalled(family) {
          Text("\(family) is no longer installed: the theme's font is used.", bundle: .module)
            .font(.caption)
            .foregroundStyle(.orange)
        }
      }
    } label: {
      title
    }
  }

  private func sampleFont(_ family: String?, code: Bool) -> Font {
    if let family = ConversationFonts.resolvedFamily(family), ConversationFonts.isInstalled(family)
    {
      return .custom(family, size: 13)
    }
    return code ? .system(size: 12, design: .monospaced) : .system(size: 13)
  }
}

/// A theme as a small picture of itself.
struct ThemeCard: View {
  let theme: ConversationTheme
  let isCurrent: Bool
  let isOther: Bool

  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      VStack(alignment: .leading, spacing: 5) {
        RoundedRectangle(cornerRadius: 4).fill(theme.bubble.color)
          .frame(width: 44, height: 10)
          .frame(maxWidth: .infinity, alignment: .trailing)
        RoundedRectangle(cornerRadius: 3).fill(theme.text.color.opacity(0.7)).frame(
          width: 70, height: 5)
        RoundedRectangle(cornerRadius: 3).fill(theme.text.color.opacity(0.45)).frame(
          width: 52, height: 5)
        HStack(spacing: 4) {
          Circle().fill(theme.accent.color).frame(width: 7, height: 7)
          RoundedRectangle(cornerRadius: 3).fill(theme.border.color).frame(width: 36, height: 5)
        }
      }
      .padding(7)
      .frame(maxWidth: .infinity, minHeight: 56, alignment: .topLeading)
      .background(theme.background.color, in: RoundedRectangle(cornerRadius: 6))
      .overlay(RoundedRectangle(cornerRadius: 6).stroke(theme.border.color))
      Text(theme.localizedName)
        .font(.caption.weight(.semibold))
        .lineLimit(1)
    }
    .padding(6)
    .background(
      RoundedRectangle(cornerRadius: 9)
        .stroke(
          isCurrent ? Color.accentColor : Color.secondary.opacity(isOther ? 0.8 : 0.25),
          style: StrokeStyle(lineWidth: isCurrent ? 2 : 1, dash: isOther ? [4, 3] : []))
    )
    .contentShape(Rectangle())
  }
}

/// A few messages drawn with the settings as they are, for the preview.
struct ConversationPreview: View {
  let theme: ConversationTheme
  let appearance: ConversationAppearance
  @State private var model = ConversationModel(sessionID: SessionID())

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: appearance.density == .compact ? 10 : 16) {
        ForEach(model.blocks) { block in
          BlockView(block: block, model: model)
        }
      }
      .padding(16)
    }
    .background(theme.background.color)
    .environment(\.conversationTheme, theme)
    .environment(\.conversationAppearance, appearance)
    .environment(\.colorScheme, theme.colorScheme)
    .allowsHitTesting(false)
    .onAppear {
      model.appearance = appearance
      model.apply(Self.sample)
    }
    .onChange(of: appearance) { model.appearance = appearance }
  }

  static var sample: ConversationSnapshot {
    let edit = ToolCall(
      callID: "edit", kind: .edit, state: .succeeded,
      parameters: [ToolParameter(.path, "Sources/TranscriptTail.swift")],
      changes: [
        FileDiff(
          path: "Sources/TranscriptTail.swift", kind: .modified,
          hunks: [
            DiffHunk(
              oldStart: 12, newStart: 12,
              lines: [
                DiffLine(kind: .removed, text: "if size < offset {", oldNumber: 12, newNumber: nil),
                DiffLine(
                  kind: .added, text: "if identifier != last || size < offset {", oldNumber: nil,
                  newNumber: 12),
              ])
          ])
      ], facts: ToolFacts(addedLines: 1, removedLines: 1))
    let tests = ToolCall(
      callID: "tests", kind: .shell, state: .failed(exitCode: 1),
      parameters: [ToolParameter(.command, "swift test")],
      facts: ToolFacts(exitCode: 1, tests: TestOutcome(total: 9, failed: 1)))
    let entries = [
      ConversationEntry(
        id: "prompt",
        content: .userPrompt(
          String(localized: "Run the tail's tests.", bundle: .module), attachments: 0)),
      ConversationEntry(id: "tests", content: .tool(tests)),
      ConversationEntry(
        id: "answer",
        content: .agentText(
          String(
            localized: "One test fails on a **replaced** file: I compare `inode` first.",
            bundle: .module))),
      ConversationEntry(id: "edit", content: .tool(edit)),
      ConversationEntry(
        id: "code", content: .agentText("```swift\nlet id = identifier(of: file) // inode\n```")),
    ]
    return ConversationSnapshot(entries: entries, availability: .available)
  }
}

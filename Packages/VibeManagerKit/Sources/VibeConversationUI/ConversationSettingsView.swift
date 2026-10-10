import AppKit
import CoreText
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
    if NSFontManager.shared.availableFontFamilies.contains(family) { return true }
    // A family a theme fetched is active for this process only, and `NSFontManager` keeps the
    // list it read first: CoreText sees it (#118). Its list is read once, and again only when a
    // family was activated since: this is asked at every drawing of a conversation.
    if activeFamilies == nil {
      activeFamilies = Set(CTFontManagerCopyAvailableFontFamilyNames() as? [String] ?? [])
    }
    return activeFamilies?.contains(family) ?? false
  }

  @MainActor private static var activeFamilies: Set<String>?

  /// Families were activated: the next question reads CoreText's list again.
  @MainActor public static func familiesDidChange() {
    activeFamilies = nil
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

/// Settings › Conversation (#38): every preference of the conversation view, with a preview that
/// follows each change. Whether sessions open on it is in General (#313). The user's own themes (#118) sit in the grid beside
/// the built-in ones, and the card at its end unfolds the panel that makes one.
public struct ConversationSettingsView: View {
  @Binding var appearance: ConversationAppearance
  @Bindable var themes: ConversationThemesModel
  @Environment(\.colorScheme) private var colorScheme
  @Environment(\.colorSchemeContrast) private var contrast
  @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
  @State private var deleting: ConversationTheme?
  @State private var exportDocument: ThemeArchiveDocument?
  @State private var exportName = ""
  @State private var isChoosingArchive = false
  @State private var isDropTargeted = false

  public init(appearance: Binding<ConversationAppearance>, themes: ConversationThemesModel) {
    _appearance = appearance
    self.themes = themes
  }

  public var body: some View {
    HStack(alignment: .top, spacing: 0) {
      Form {
        Section {
          Toggle(isOn: $appearance.followsSystemAppearance) {
            Text("Follow light and dark mode", bundle: .module)
          }
          themeGrid
          if appearance.followsSystemAppearance {
            Text(
              "In light mode: \(themeName(appearance.lightTheme, isDark: false)). In dark mode: \(themeName(appearance.darkTheme, isDark: true)). Choosing a theme gives it to the mode macOS is in.",
              bundle: .module
            )
            .font(.caption)
            .foregroundStyle(.secondary)
          }
          if !themes.loadProblems.isEmpty {
            ThemeLoadProblemsView(themes: themes)
          }
          // A failure to export or delete, said where the user acted: the panel may be folded.
          if !themes.isOpen, let problem = themes.problem {
            Label {
              Text(problem.message)
            } icon: {
              Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            }
            .font(.callout)
          }
          if let saved = themes.lastSaved {
            Label {
              Text(ConversationThemesModel.savedSentence(saved.name, saved.mode))
            } icon: {
              Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
            }
            .font(.callout)
          }
          if let imported = themes.lastImported {
            Label {
              VStack(alignment: .leading, spacing: 2) {
                Text(ConversationThemesModel.importedSentence(imported.name, imported.mode))
                ForEach(imported.missingFonts, id: \.self) { family in
                  Text(ConversationThemesModel.missingFontSentence(family))
                    .foregroundStyle(.secondary)
                }
              }
            } icon: {
              Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
            }
            .font(.callout)
          }
          if themes.isOpen {
            ThemeWorkshopPanel(
              themes: themes, appearance: $appearance, systemIsDark: colorScheme == .dark)
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
            Text(
              "Also sizes the terminals. ⌘+ and ⌘− in the View menu.", bundle: .module,
              comment:
                "Under the text size setting: it also sizes the terminals, and the View menu's zoom changes it."
            )
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
        HStack {
          Text("Preview", bundle: .module).font(.headline)
          Spacer()
          if themes.trial != nil {
            Text("On trial — not saved", bundle: .module)
              .font(.caption)
              .padding(.horizontal, 6)
              .padding(.vertical, 2)
              .background(Capsule().fill(Color.orange.opacity(0.2)))
          }
        }
        ConversationPreview(theme: currentTheme, appearance: installedAppearance)
          .frame(width: 360, height: 420)
          .clipShape(RoundedRectangle(cornerRadius: 12))
          .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.secondary.opacity(0.3)))
        (themes.trial != nil
          ? Text(
            "The theme on trial also applies to the conversations of the main window. Folding the panel, choosing another card or leaving the tab without saving brings back the theme in force.",
            bundle: .module)
          : Text(
            "The theme applies to the conversation view of every session. The terminal keeps the colours the agent sends it.",
            bundle: .module))
          .font(.caption)
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
      }
      .padding(20)
      .frame(width: 400)
    }
    // The library is read again each time the tab appears: another instance may have changed it.
    .task { await themes.load() }
    // Leaving the tab, or closing the window, drops the theme on trial.
    .onDisappear { themes.close() }
  }

  private var installedAppearance: ConversationAppearance {
    ConversationFonts.installedOnly(appearance)
  }

  private var currentTheme: ConversationTheme {
    themes.displayed(
      installedAppearance, isDark: colorScheme == .dark, increasedContrast: contrast == .increased,
      reducedTransparency: reduceTransparency)
  }

  /// A theme no longer there is named as the one drawn in its place: the mode's default.
  private func themeName(_ id: String, isDark: Bool) -> String {
    (themes.theme(id) ?? (isDark ? .systemDark : .systemLight)).displayName
  }

  private var themeGrid: some View {
    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: 3), spacing: 10)
    {
      ForEach(ConversationTheme.builtIn + themes.personal) { theme in
        themeCard(theme)
      }
      // Making a theme needs an agent; importing one does not (#361).
      NewThemeCard(
        canCreate: themes.canCreate, isOpen: themes.isOpen,
        create: { themes.toggle(systemIsDark: colorScheme == .dark) },
        importArchive: { isChoosingArchive = true })
    }
    // A theme's archive dropped on the grid is imported, as one chosen in the open panel.
    .dropDestination(for: URL.self) { urls, _ in
      guard urls.count == 1, let url = urls.first, url.pathExtension.lowercased() == "zip" else {
        return false
      }
      importArchive(at: url)
      return true
    } isTargeted: {
      isDropTargeted = $0
    }
    .overlay {
      if isDropTargeted {
        RoundedRectangle(cornerRadius: 10)
          .fill(Color.accentColor.opacity(0.1))
          .strokeBorder(Color.accentColor, style: StrokeStyle(lineWidth: 2, dash: [5, 4]))
          .overlay {
            Label {
              Text("Drop to Import the Theme", bundle: .module)
            } icon: {
              Image(systemName: "square.and.arrow.down")
            }
            .font(.callout.weight(.semibold))
            .foregroundStyle(Color.accentColor)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
          }
          .padding(-4)
          .allowsHitTesting(false)
      }
    }
    .fileImporter(isPresented: $isChoosingArchive, allowedContentTypes: [.zip]) { result in
      guard case .success(let url) = result else { return }
      importArchive(at: url)
    }
    .alert(
      Text("Delete the Theme “\(deleting?.displayName ?? "")”?", bundle: .module),
      isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }),
      presenting: deleting
    ) { theme in
      Button(role: .destructive) {
        Task {
          if let updated = await themes.delete(theme.id, from: appearance) { appearance = updated }
        }
      } label: {
        Text("Delete", bundle: .module)
      }
      Button(role: .cancel) {
        // The alert goes away by itself: nothing is deleted.
      } label: {
        Text("Cancel", bundle: .module)
      }
    } message: { theme in
      deletionMessage(theme)
    }
    .fileExporter(
      isPresented: Binding(
        get: { exportDocument != nil }, set: { if !$0 { exportDocument = nil } }),
      document: exportDocument, contentType: .zip, defaultFilename: exportName
    ) { _ in
      exportDocument = nil
    }
  }

  private func themeCard(_ theme: ConversationTheme) -> some View {
    let isLight = appearance.lightTheme == theme.id
    let isDark = appearance.followsSystemAppearance && appearance.darkTheme == theme.id
    let isCurrent =
      appearance.followsSystemAppearance && colorScheme == .dark ? isDark : isLight
    return Button {
      themes.close()
      themes.dismissConfirmation()
      if appearance.followsSystemAppearance, colorScheme == .dark {
        appearance.darkTheme = theme.id
      } else {
        appearance.lightTheme = theme.id
      }
    } label: {
      ThemeCard(theme: theme, isCurrent: isCurrent, isOther: !isCurrent && (isLight || isDark))
    }
    .buttonStyle(.plain)
    .accessibilityLabel(
      theme.isPersonal
        ? Text("\(theme.displayName), a theme of yours", bundle: .module)
        : Text(theme.localizedName)
    )
    .accessibilityAddTraits(isCurrent ? .isSelected : [])
    .contextMenu {
      if theme.isPersonal {
        Button {
          export(theme)
        } label: {
          Text("Export…", bundle: .module)
        }
        Divider()
        Button {
          deleting = theme
        } label: {
          Text("Delete…", bundle: .module)
        }
      }
    }
    .accessibilityActions {
      if theme.isPersonal {
        Button {
          export(theme)
        } label: {
          Text("Export…", bundle: .module)
        }
        Button {
          deleting = theme
        } label: {
          Text("Delete…", bundle: .module)
        }
      }
    }
    .onDeleteCommand {
      if theme.isPersonal { deleting = theme }
    }
  }

  private func deletionMessage(_ theme: ConversationTheme) -> Text {
    let usedLight = appearance.lightTheme == theme.id
    let usedDark = appearance.followsSystemAppearance && appearance.darkTheme == theme.id
    let lightDefault = ConversationTheme.systemLight.displayName
    let darkDefault = ConversationTheme.systemDark.displayName
    switch (usedLight, usedDark) {
    case (true, true):
      return Text(
        "It is used in light and dark mode: the conversations go back to \(lightDefault) and \(darkDefault). Its file is deleted.",
        bundle: .module)
    case (true, false):
      return Text(
        "It is used in light mode: the conversations go back to \(lightDefault). Its file is deleted.",
        bundle: .module)
    case (false, true):
      return Text(
        "It is used in dark mode: the conversations go back to \(darkDefault). Its file is deleted.",
        bundle: .module)
    case (false, false):
      return Text("Its file is deleted.", bundle: .module)
    }
  }

  /// Reads the archive at `url` — chosen, or dropped — with the bound of the archive itself: a
  /// larger file is not read at all.
  private func importArchive(at url: URL) {
    let fileName = url.lastPathComponent
    let scoped = url.startAccessingSecurityScopedResource()
    defer { if scoped { url.stopAccessingSecurityScopedResource() } }
    guard let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize else {
      themes.refuseImport(fileName, .notATheme)
      return
    }
    guard size <= ConversationThemesModel.maximumArchiveSize else {
      themes.refuseImport(fileName, .tooLarge)
      return
    }
    guard let data = try? Data(contentsOf: url) else {
      themes.refuseImport(fileName, .notATheme)
      return
    }
    Task {
      if let updated = await themes.importArchive(data, named: fileName, into: appearance) {
        appearance = updated
      }
    }
  }

  private func export(_ theme: ConversationTheme) {
    let preview = ThemePreviewImage.png(of: theme)
    Task {
      guard let data = await themes.archive(theme.id, preview: preview) else { return }
      exportName = "\(theme.displayName).zip"
      exportDocument = ThemeArchiveDocument(data: data)
    }
  }

  private var accentRow: some View {
    LabeledContent {
      HStack(spacing: 8) {
        ForEach(ConversationAppearance.Accent.allCases.filter { $0 != .custom }, id: \.self) {
          accent in
          Button {
            appearance.accent = accent
          } label: {
            Circle()
              .fill(swatch(accent))
              .frame(width: 18, height: 18)
              .overlay(
                Circle().stroke(Color.accentColor, lineWidth: appearance.accent == accent ? 2 : 0)
                  .padding(-3)
              )
              // At least 20 points to click (#229), the disc drawn at its own size.
              .frame(width: 20, height: 20)
              .contentShape(Rectangle())
          }
          .buttonStyle(.plain)
          .help(Text(Self.accentName(accent)))
          .accessibilityLabel(Text(Self.accentName(accent)))
          .accessibilityAddTraits(appearance.accent == accent ? .isSelected : [])
        }
        // Any colour at all: the system's colour picker.
        ColorPicker(selection: customAccent, supportsOpacity: false) {
          Text("Custom", bundle: .module)
        }
        .labelsHidden()
        .overlay(
          Circle().stroke(Color.accentColor, lineWidth: appearance.accent == .custom ? 2 : 0)
            .frame(width: 24, height: 24)
            .allowsHitTesting(false)
        )
        .help(Text("Choose a colour of your own", bundle: .module))
        .accessibilityLabel(Text("Custom colour", bundle: .module))
        Text(Self.accentName(appearance.accent))
          .font(.caption)
          .foregroundStyle(.secondary)
          .fixedSize()
      }
    } label: {
      Text("Accent colour", bundle: .module)
    }
  }

  /// The colour picker's colour: the one chosen, or the accent in force until one is.
  private var customAccent: Binding<Color> {
    Binding(
      get: { currentTheme.accent.color },
      set: { color in
        guard let chosen = ThemeColor(color) else { return }
        appearance.customAccent = chosen.hex
        appearance.accent = .custom
      })
  }

  private func swatch(_ accent: ConversationAppearance.Accent) -> AnyShapeStyle {
    guard let colors = ConversationTheme.accentColors[accent] else {
      // The theme's own accent, as the current theme draws it.
      let base =
        themes.theme(appearance.themeIdentifier(isDark: colorScheme == .dark))
        ?? (colorScheme == .dark ? .systemDark : .systemLight)
      return AnyShapeStyle(base.accent.color)
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
    case .custom: return LocalizedStringResource("Custom colour", bundle: .module)
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
  /// Said under the picture in place of the theme's name: what choosing the card means (#274).
  var title: Text? = nil

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
      .background(ThemeBackdropView(theme: theme).clipShape(RoundedRectangle(cornerRadius: 6)))
      .overlay(RoundedRectangle(cornerRadius: 6).stroke(theme.border.color))
      HStack(spacing: 4) {
        if let title {
          title
            .lineLimit(1)
        } else if let name = theme.personalName {
          Text(verbatim: name)
            .lineLimit(1)
          Text("Mine", bundle: .module, comment: "A mark on the card of a theme the user made.")
            .font(.system(size: 9, weight: .semibold))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 4)
            .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color.secondary.opacity(0.5)))
            .accessibilityHidden(true)
        } else {
          Text(theme.localizedName)
            .lineLimit(1)
        }
      }
      .font(.caption.weight(.semibold))
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
      VStack(alignment: .leading, spacing: theme.layout.at(appearance.density).blockSpacing) {
        ForEach(model.blocks) { block in
          BlockView(block: block, model: model)
        }
      }
      .padding(16)
    }
    .background(ThemeBackdropView(theme: theme))
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
          String(localized: "Run the tail's tests.", bundle: .module), attachments: [])),
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

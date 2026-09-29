import AppKit
import SwiftUI
import UniformTypeIdentifiers
import VibeApplication

/// The panel under the grid of themes that makes one (#118): what the user describes, a button
/// per agent that can make it, the versions made so far, and saving.
struct ThemeWorkshopPanel: View {
  @Bindable var themes: ConversationThemesModel
  @Binding var appearance: ConversationAppearance
  let systemIsDark: Bool
  @FocusState private var promptFocused: Bool

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      HStack {
        Text("Create My Theme", bundle: .module).font(.headline)
        Spacer()
        Button {
          themes.close()
        } label: {
          Image(systemName: "chevron.up")
        }
        .buttonStyle(.borderless)
        .help(Text("Fold the panel: a theme not saved is dropped", bundle: .module))
        .accessibilityLabel(Text("Fold the panel", bundle: .module))
      }
      if !themes.optionsLoaded {
        ProgressView().controlSize(.small)
      } else if themes.options.isEmpty {
        noAgents
      } else {
        workshop
      }
    }
    .padding(12)
    .background(
      RoundedRectangle(cornerRadius: 8).fill(Color.secondary.opacity(0.08))
    )
    // The description takes the keyboard as soon as it is there: the agents are asked first.
    .onChange(of: themes.optionsLoaded, initial: true) { _, loaded in
      if loaded { promptFocused = true }
    }
  }

  private var noAgents: some View {
    VStack(alignment: .leading, spacing: 8) {
      Text("No agent can make a theme now", bundle: .module).font(.subheadline.weight(.semibold))
      Text(
        "Install Claude Code or Codex and sign in from a terminal, then check again.",
        bundle: .module
      )
      .font(.callout)
      .foregroundStyle(.secondary)
      .fixedSize(horizontal: false, vertical: true)
      Button {
        Task { await themes.refreshOptions() }
      } label: {
        Text("Check Again", bundle: .module)
      }
    }
  }

  @ViewBuilder private var workshop: some View {
    Picker(selection: $themes.targetDark) {
      Text("Light", bundle: .module).tag(false)
      Text("Dark", bundle: .module).tag(true)
    } label: {
      Text("For", bundle: .module)
    }
    .pickerStyle(.segmented)
    .disabled(!themes.versions.isEmpty || themes.isGenerating)
    .help(
      themes.versions.isEmpty
        ? Text("The mode the theme is made for", bundle: .module)
        : Text("Start over to make a theme for the other mode", bundle: .module))

    VStack(alignment: .leading, spacing: 4) {
      (themes.versions.isEmpty
        ? Text("Describe the theme you want", bundle: .module)
        : Text("What should change?", bundle: .module))
        .font(.callout)
        .foregroundStyle(.secondary)
      TextField(
        text: $themes.prompt,
        prompt: themes.versions.isEmpty
          ? Text("A forest at night: moss greens, quiet, easy on the eyes…", bundle: .module)
          : Text("More contrast, a green accent, darker code…", bundle: .module),
        axis: .vertical
      ) {
        themes.versions.isEmpty
          ? Text("Describe the theme you want", bundle: .module)
          : Text("What should change?", bundle: .module)
      }
      .labelsHidden()
      .lineLimit(3...6)
      .textFieldStyle(.roundedBorder)
      .focused($promptFocused)
      .disabled(themes.isGenerating)
    }

    if themes.isGenerating {
      HStack(alignment: .top, spacing: 10) {
        ProgressView().controlSize(.small)
        VStack(alignment: .leading, spacing: 2) {
          busyText
          if themes.isRetrying {
            Text(
              "The first answer could not be used: it is asked once more.", bundle: .module
            )
            .font(.caption)
            .foregroundStyle(.orange)
          }
        }
        Spacer()
        Button {
          themes.cancel()
        } label: {
          Text("Cancel", bundle: .module)
        }
        .keyboardShortcut(.cancelAction)
      }
      .accessibilityElement(children: .contain)
    } else {
      HStack(spacing: 8) {
        ForEach(themes.options) { option in
          Button {
            themes.generate(with: option)
          } label: {
            Text("Generate with \(option.descriptor.displayName)", bundle: .module)
          }
          .disabled(!themes.canGenerate)
        }
      }
    }

    if let problem = themes.problem {
      Label {
        Text(problem.message)
      } icon: {
        Image(systemName: "exclamationmark.triangle.fill")
      }
      .font(.callout)
      .foregroundStyle(.orange)
      .fixedSize(horizontal: false, vertical: true)
    }

    if !themes.versions.isEmpty {
      versions
      accentChoice
      HStack {
        TextField(
          text: Binding(
            get: { themes.name },
            set: { themes.editName(String($0.prefix(ConversationThemeFile.maximumNameLength))) }),
          prompt: Text("Name of the theme", bundle: .module)
        ) {
          Text("Name", bundle: .module)
        }
        .disabled(themes.isGenerating || themes.isSaving)
      }
      HStack {
        Spacer()
        if themes.isSaving { ProgressView().controlSize(.small) }
        Button {
          Task {
            if let updated = await themes.save(into: appearance) { appearance = updated }
          }
        } label: {
          Text("Save and Apply the Theme", bundle: .module)
        }
        .buttonStyle(.borderedProminent)
        .disabled(!themes.canSave)
      }
    }
  }

  /// What is under way: the theme, then its picture.
  private var busyText: Text {
    let agent = themes.generatingAgent ?? ""
    if themes.isMakingPicture {
      return themes.generatingAgent == nil
        ? Text("Fetching the picture…", bundle: .module)
        : Text("\(agent) is drawing the picture… It takes a minute or two.", bundle: .module)
    }
    return themes.versions.isEmpty
      ? Text("\(agent) is making the theme…", bundle: .module)
      : Text("\(agent) is changing the theme…", bundle: .module)
  }

  private var versions: some View {
    VStack(alignment: .leading, spacing: 6) {
      Text("Versions", bundle: .module)
        .font(.caption.weight(.semibold))
        .foregroundStyle(.secondary)
      VStack(alignment: .leading, spacing: 0) {
        ForEach(Array(themes.versions.enumerated()), id: \.element.id) { index, version in
          HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(verbatim: "\(index + 1)")
              .font(.caption.monospacedDigit())
              .foregroundStyle(.secondary)
            Text(verbatim: "“\(version.request)”")
              .lineLimit(2)
            Spacer()
            Text(verbatim: version.agentName)
              .font(.caption)
              .foregroundStyle(.secondary)
            if index == themes.versions.count - 1 {
              Text("on trial", bundle: .module)
                .font(.caption2.weight(.semibold))
                .padding(.horizontal, 5)
                .background(Capsule().fill(Color.accentColor.opacity(0.2)))
            }
          }
          .padding(.vertical, 5)
          .accessibilityElement(children: .ignore)
          .accessibilityLabel(
            Text(
              "Version \(index + 1), \(version.request), \(version.agentName)", bundle: .module))
          if index < themes.versions.count - 1 { Divider() }
        }
      }
      HStack(spacing: 14) {
        Button {
          themes.back()
        } label: {
          Text("Go Back to the Previous Version", bundle: .module)
        }
        Button {
          themes.restart()
        } label: {
          Text("Start Over", bundle: .module)
        }
      }
      .buttonStyle(.link)
      .disabled(themes.isGenerating)
    }
  }

  /// Only when the user chose an accent of their own: it would hide the one the agent chose.
  @ViewBuilder private var accentChoice: some View {
    if appearance.accent != .theme {
      VStack(alignment: .leading, spacing: 2) {
        Toggle(isOn: $themes.usesThemeAccent) {
          Text("Use the theme's accent", bundle: .module)
        }
        Text(
          "Otherwise your accent, \(Text(ConversationSettingsView.accentName(appearance.accent))), replaces the one generated.",
          bundle: .module
        )
        .font(.caption)
        .foregroundStyle(.secondary)
      }
    }
  }
}

/// The card at the end of the grid that unfolds the panel.
struct CreateThemeCard: View {
  let isOpen: Bool

  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      Image(systemName: "plus")
        .font(.system(size: 16, weight: .medium))
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity, minHeight: 56)
        .background(
          RoundedRectangle(cornerRadius: 6)
            .strokeBorder(
              Color.secondary.opacity(0.6), style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
        )
      Text("Create My Theme", bundle: .module)
        .font(.caption.weight(.semibold))
        .lineLimit(1)
    }
    .padding(6)
    .background(
      RoundedRectangle(cornerRadius: 9)
        .stroke(
          isOpen ? Color.accentColor : Color.secondary.opacity(0.25), lineWidth: isOpen ? 2 : 1)
    )
    .contentShape(Rectangle())
  }
}

/// The `.zip` of a theme, for the save panel.
struct ThemeArchiveDocument: FileDocument {
  static let readableContentTypes: [UTType] = [.zip]

  let data: Data

  init(data: Data) {
    self.data = data
  }

  init(configuration: ReadConfiguration) throws {
    data = configuration.file.regularFileContents ?? Data()
  }

  func fileWrapper(configuration _: WriteConfiguration) throws -> FileWrapper {
    FileWrapper(regularFileWithContents: data)
  }
}

/// The picture of a theme an export holds: its card, drawn twice as large.
@MainActor
enum ThemePreviewImage {
  static func png(of theme: ConversationTheme) -> Data? {
    let card = ThemeCard(theme: theme, isCurrent: false, isOther: false)
      .frame(width: 160)
      .padding(8)
      .background(theme.isDark ? Color.black : Color.white)
      .environment(\.colorScheme, theme.colorScheme)
    let renderer = ImageRenderer(content: card)
    renderer.scale = 2
    guard let image = renderer.cgImage else { return nil }
    let bitmap = NSBitmapImageRep(cgImage: image)
    return bitmap.representation(using: .png, properties: [:])
  }
}

/// The files of the library that could not be read: left out, left where they are, and said.
struct ThemeLoadProblemsView: View {
  let themes: ConversationThemesModel

  var body: some View {
    VStack(alignment: .leading, spacing: 4) {
      Label {
        Text("Some theme files could not be read, and are not offered:", bundle: .module)
      } icon: {
        Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
      }
      ForEach(themes.loadProblems, id: \.fileName) { problem in
        Text(
          "\(problem.fileName): \(Text(Self.reason(problem.problem)))", bundle: .module
        )
        .foregroundStyle(.secondary)
      }
      Button {
        let urls = themes.loadProblems.compactMap { themes.location(ofFile: $0.fileName) }
        NSWorkspace.shared.activateFileViewerSelecting(urls)
      } label: {
        Text("Show in Finder", bundle: .module)
      }
      .buttonStyle(.link)
    }
    .font(.caption)
  }

  static func reason(_ problem: ThemeFileProblem) -> LocalizedStringResource {
    switch problem {
    case .tooLarge:
      LocalizedStringResource("too large to be a theme", bundle: .module)
    case .notJSON:
      LocalizedStringResource("not a theme file", bundle: .module)
    case .unknownFormat:
      LocalizedStringResource("made by a later version of Vibe Manager", bundle: .module)
    case .missingKey(let key):
      LocalizedStringResource("“\(key)” is missing", bundle: .module)
    case .unknownKey(let key):
      LocalizedStringResource("“\(key)” is unknown", bundle: .module)
    case .invalidValue(let key):
      LocalizedStringResource("“\(key)” is not valid", bundle: .module)
    case .invalidName:
      LocalizedStringResource("its name cannot be used", bundle: .module)
    case .wrongMode:
      LocalizedStringResource("not of the mode expected", bundle: .module)
    case .illegible:
      LocalizedStringResource("some of its colours cannot be read on each other", bundle: .module)
    case .outOfRange(let key, _):
      LocalizedStringResource("“\(key)” is out of range", bundle: .module)
    case .unknownFont(_, let family):
      LocalizedStringResource("the font “\(family)” cannot be found", bundle: .module)
    case .inventedImageURL:
      LocalizedStringResource(
        "the address of its picture was not given by the user", bundle: .module)
    }
  }
}

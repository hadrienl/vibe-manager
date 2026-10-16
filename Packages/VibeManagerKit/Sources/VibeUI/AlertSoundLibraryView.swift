import AppKit
import SwiftUI
import UniformTypeIdentifiers
import VibeApplication
import VibeConversationUI

/// Settings › Notifications › Sounds (#393), on the layout of the avatars' page: the sounds in a
/// list — the system's default, none, the user's own, those shipped, those of macOS — with the card
/// that makes a new one, and the one selected in a preview beside it. Selecting a sound plays it;
/// "Use This Sound" alone changes the one in use.
struct AlertSoundLibraryView: View {
  @Bindable var sounds: AlertSoundLibraryModel
  /// Whether the card that makes a new sound is unfolded. Not kept: the page opens with it folded.
  @State var isCreating = false
  @State var isChoosingFile = false
  @State var isDropTargeted = false
  @State var exportDocument: WaveDocument?
  @State var exportName = ""
  @State var isExporting = false
  /// The sound being renamed, and the name typed.
  @State var renaming: AlertSoundID?
  @State var newName = ""
  /// The sound whose deletion waits for its confirmation.
  @State var deleting: AlertSoundID?
  @FocusState var isDescriptionFocused: Bool
  @Environment(\.locale) var locale

  /// The widths of the avatars' page.
  static let listWidth: CGFloat = AvatarLibraryView.listWidth
  static let previewWidth: CGFloat = AvatarLibraryView.previewWidth
  static let cardID = "new-sound-card"

  var body: some View {
    HStack(spacing: 0) {
      list
        .frame(width: Self.listWidth)
      Divider()
      AlertSoundPreviewPane(sounds: sounds, export: export, rename: startRenaming) {
        deleting = $0
      }
      .frame(width: Self.previewWidth)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    .task {
      sounds.showOutlines()
      await sounds.refreshOptions()
    }
    .fileImporter(isPresented: $isChoosingFile, allowedContentTypes: [.audio]) { result in
      guard case .success(let url) = result else { return }
      Task { await sounds.importFile(url) }
    }
    .fileExporter(
      isPresented: $isExporting, document: exportDocument, contentType: .wav,
      defaultFilename: exportName
    ) { _ in
      exportDocument = nil
    }
    .alert(
      Text("Rename the Sound", bundle: .module),
      isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })
    ) {
      TextField(text: $newName) {
        Text("Name", bundle: .module)
      }
      Button {
        if let id = renaming {
          let name = newName
          Task { await sounds.rename(id, to: name) }
        }
        renaming = nil
      } label: {
        Text("Rename", bundle: .module)
      }
      .disabled(AlertSoundRules.name(newName) == nil)
      Button(role: .cancel) {
        renaming = nil
      } label: {
        Text("Cancel", bundle: .module)
      }
    } message: {
      Text("\(AlertSoundRules.maximumNameLength) characters at most.", bundle: .module)
    }
    .confirmationDialog(
      deletionTitle,
      isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }),
      titleVisibility: .visible, presenting: deleting
    ) { id in
      Button(role: .destructive) {
        Task { await sounds.remove(id) }
        deleting = nil
      } label: {
        Text("Delete", bundle: .module)
      }
      Button(role: .cancel) {
        deleting = nil
      } label: {
        Text("Cancel", bundle: .module)
      }
    } message: { id in
      if sounds.choice == .custom(id) {
        Text(
          "It is the alert sound: the system's default will play instead. It cannot be recovered.",
          bundle: .module)
      } else {
        Text("It cannot be recovered. Export it first to keep it.", bundle: .module)
      }
    }
    .alert(
      importTitle,
      isPresented: Binding(
        get: { importMessage != nil }, set: { if !$0 { sounds.dismissProblem() } })
    ) {
      Button {
        sounds.dismissProblem()
      } label: {
        Text("OK", bundle: .module)
      }
    } message: {
      if let importMessage { Text(importMessage) }
    }
  }

  // MARK: - The list

  private var list: some View {
    VStack(alignment: .leading, spacing: 8) {
      HStack(alignment: .firstTextBaseline) {
        Text("Sounds", bundle: .module, comment: "The list of the alert sounds.").font(.headline)
        Spacer()
        Text(summary)
          .font(.caption)
          .monospacedDigit()
          .foregroundStyle(.secondary)
      }
      List(selection: selection) {
        ForEach([AlertSoundChoice.systemDefault, .none], id: \.self) { choice in
          soundRow(choice)
        }
        Section {
          ForEach(sounds.entries) { entry in
            soundRow(.custom(entry.id))
          }
          ForEach(sounds.jobs.filter { $0.target == nil }) { job in
            AlertSoundJobRow(sounds: sounds, job: job)
              .tag(AlertSoundLibraryModel.Selection.job(job.id))
          }
          if sounds.isImporting {
            HStack(spacing: 11) {
              AvatarThumbnail { ProgressView().controlSize(.small) }
              Text("Reading the file…", bundle: .module).foregroundStyle(.secondary)
              Spacer()
            }
            .padding(.vertical, 4)
            .selectionDisabled()
          }
          NewAlertSoundCard(
            sounds: sounds, isExpanded: $isCreating, isDescriptionFocused: $isDescriptionFocused,
            chooseFile: { isChoosingFile = true },
            generate: {
              sounds.generate()
              isCreating = false
            }
          )
          .selectionDisabled()
          .id(Self.cardID)
        } header: {
          Text("My Sounds", bundle: .module, comment: "The user's own alert sounds.")
        }
        Section {
          ForEach(BundledAlertSound.allCases, id: \.self) { sound in
            soundRow(.bundled(sound.rawValue))
          }
        } header: {
          Text(verbatim: "Vibe Manager")
        }
        if !sounds.systemSounds.isEmpty {
          Section {
            ForEach(sounds.systemSounds, id: \.self) { name in
              soundRow(.macOS(name))
            }
          } header: {
            Text(verbatim: "macOS")
          }
        }
      }
      .listStyle(.inset)
      .accessibilityLabel(Text("Sounds", bundle: .module, comment: "The list of the alert sounds."))
      .accessibilityIdentifier("alert-sound-list")
      Text(
        "An audio file dropped on the list is imported: 30 seconds at most.", bundle: .module
      )
      .font(.caption)
      .foregroundStyle(.secondary)
      .fixedSize(horizontal: false, vertical: true)
    }
    .padding(EdgeInsets(top: 14, leading: 20, bottom: 12, trailing: 20))
    .dropDestination(for: URL.self) { urls, _ in
      guard let url = urls.first, sounds.isIdle else { return false }
      Task { await sounds.importFile(url) }
      return true
    } isTargeted: {
      isDropTargeted = $0
    }
    .overlay(
      RoundedRectangle(cornerRadius: 10)
        .strokeBorder(Color.accentColor, lineWidth: isDropTargeted ? 3 : 0)
        .padding(6)
        .allowsHitTesting(false))
  }

  private func soundRow(_ choice: AlertSoundChoice) -> some View {
    AlertSoundRow(sounds: sounds, choice: choice, isSelected: sounds.selectedSound == choice) {
      if case .custom(let id) = choice { menuItems(for: id) }
    }
    .tag(AlertSoundLibraryModel.Selection.sound(choice))
    .contextMenu {
      if case .custom(let id) = choice { menuItems(for: id) }
    }
  }

  private var summary: String {
    let count = sounds.entries.count
    let size = ByteCountFormatter.string(fromByteCount: sounds.byteCount, countStyle: .file)
    return String(
      localized: LocalizedStringResource(
        "\(count) sounds · \(size)", bundle: .module,
        comment: "How many sounds of the user's own, and what they take on disk."))
  }

  private var selection: Binding<AlertSoundLibraryModel.Selection?> {
    Binding(get: { sounds.selection }, set: { sounds.select($0) })
  }

  // MARK: - Actions

  /// The actions of a sound of the user's own, in its menus.
  @ViewBuilder
  func menuItems(for id: AlertSoundID) -> some View {
    Button {
      sounds.use(.custom(id))
    } label: {
      Text("Use This Sound", bundle: .module)
    }
    .disabled(sounds.choice == .custom(id))
    Button {
      startRenaming(id)
    } label: {
      Text("Rename…", bundle: .module)
    }
    Button {
      export(id)
    } label: {
      Text("Export…", bundle: .module)
    }
    Divider()
    Button(role: .destructive) {
      deleting = id
    } label: {
      Text("Delete…", bundle: .module)
    }
  }

  func startRenaming(_ id: AlertSoundID) {
    guard let entry = sounds.entry(id) else { return }
    newName = entry.name
    renaming = id
  }

  func export(_ id: AlertSoundID) {
    guard let entry = sounds.entry(id) else { return }
    Task {
      guard let data = await sounds.exportData(id) else { return }
      exportName = entry.name
      exportDocument = WaveDocument(data: data)
      isExporting = true
    }
  }

  private var deletionTitle: Text {
    guard let id = deleting, let entry = sounds.entry(id) else { return Text(verbatim: "") }
    return Text("Delete “\(DisplaySafeText.visible(entry.name))”?", bundle: .module)
  }

  /// The refusal of a file, or of a new sound: said in an alert, where the user acted.
  private var importMessage: LocalizedStringResource? {
    switch sounds.problem {
    case .importing, .limitReached: sounds.problem.map(AlertSoundPresentation.message(for:))
    default: nil
    }
  }

  private var importTitle: Text {
    if case .importing(_, let file) = sounds.problem {
      return Text("“\(file)” is not imported", bundle: .module)
    }
    return Text("No sound is added", bundle: .module)
  }
}

/// A WAV file to export.
struct WaveDocument: FileDocument {
  static let readableContentTypes: [UTType] = [.wav]
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

// MARK: - Rows

/// The shape of a sound: its loudness over time, in bars.
struct AlertSoundOutline: View {
  let values: [Float]
  var barWidth: CGFloat = 2
  var spacing: CGFloat = 1.5
  var tint: Color = .accentColor

  var body: some View {
    GeometryReader { geometry in
      let count = max(1, Int((geometry.size.width + spacing) / (barWidth + spacing)))
      let bars = Self.resample(values, to: count)
      HStack(alignment: .center, spacing: spacing) {
        ForEach(bars.indices, id: \.self) { index in
          Capsule()
            .fill(tint)
            .frame(width: barWidth, height: max(2, CGFloat(bars[index]) * geometry.size.height))
        }
      }
      .frame(width: geometry.size.width, height: geometry.size.height, alignment: .leading)
    }
    .accessibilityHidden(true)
  }

  /// The loudest of each group of points.
  static func resample(_ values: [Float], to count: Int) -> [Float] {
    guard !values.isEmpty, count > 0 else { return [] }
    return (0..<count).map { index in
      let start = index * values.count / count
      let end = max(start + 1, (index + 1) * values.count / count)
      return values[start..<min(end, values.count)].max() ?? 0
    }
  }
}

/// The square a sound's shape, or its kind, is shown in.
struct AlertSoundThumbnail: View {
  let sounds: AlertSoundLibraryModel
  let choice: AlertSoundChoice
  var size: CGFloat = 46

  var body: some View {
    AvatarThumbnail(size: size) {
      switch choice {
      case .systemDefault:
        Image(systemName: "speaker.wave.2")
          .font(.system(size: size * 0.38))
          .foregroundStyle(.secondary)
      case .none:
        Image(systemName: "speaker.slash")
          .font(.system(size: size * 0.38))
          .foregroundStyle(.secondary)
      default:
        if let outline = sounds.outlines[choice] {
          AlertSoundOutline(
            values: outline, barWidth: size > 30 ? 2.5 : 2, spacing: size > 30 ? 2 : 1.5,
            tint: isSystem ? .secondary : .accentColor
          )
          .padding(.horizontal, size * 0.16)
          .padding(.vertical, size * 0.2)
        } else {
          Color.clear
        }
      }
    }
  }

  private var isSystem: Bool {
    if case .macOS = choice { return true }
    return false
  }
}

/// A sound of the list: its shape, its name, where it comes from, and whether it is in use.
struct AlertSoundRow<Menu: View>: View {
  let sounds: AlertSoundLibraryModel
  let choice: AlertSoundChoice
  let isSelected: Bool
  @ViewBuilder let menu: () -> Menu
  @Environment(\.locale) private var locale

  var body: some View {
    let name = AlertSoundPresentation.name(of: choice, in: sounds)
    HStack(spacing: 11) {
      AlertSoundThumbnail(sounds: sounds, choice: choice)
      VStack(alignment: .leading, spacing: 1) {
        Text(verbatim: name)
          .fontWeight(.semibold)
          .lineLimit(1)
          .truncationMode(.middle)
        Text(verbatim: subtitle)
          .font(.caption)
          .foregroundStyle(.secondary)
          .lineLimit(1)
      }
      Spacer(minLength: 8)
      if let work = changing {
        ProgressView().controlSize(.small)
          .accessibilityLabel(
            Text(
              "\(AlertSoundPresentation.agentName(work.provider.rawValue, in: sounds)) is changing the sound.",
              bundle: .module))
      }
      if choice == sounds.inUse {
        AvatarBadge(kind: .inUse)
      }
      if isSelected, case .custom = choice {
        SwiftUI.Menu {
          menu()
        } label: {
          Image(systemName: "ellipsis.circle")
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .accessibilityLabel(Text("More Actions", bundle: .module))
      }
    }
    .padding(.vertical, 4)
    .accessibilityElement(children: .combine)
    .accessibilityAddTraits(isSelected ? .isSelected : [])
    .accessibilityIdentifier("alert-sound-row")
  }

  /// A change of this sound under way.
  private var changing: AlertSoundLibraryModel.Job? {
    guard case .custom(let id) = choice, let work = sounds.work, work.target == id else {
      return nil
    }
    return work
  }

  private var subtitle: String {
    let origin = AlertSoundPresentation.origin(of: choice, in: sounds)
    guard let duration = sounds.durations[choice], case .custom = choice else { return origin }
    return "\(origin) · \(AlertSoundPresentation.duration(duration, locale: locale))"
  }
}

/// A composition that is not a sound yet: under way, or failed.
struct AlertSoundJobRow: View {
  let sounds: AlertSoundLibraryModel
  let job: AlertSoundLibraryModel.Job
  @Environment(\.locale) private var locale

  var body: some View {
    HStack(spacing: 11) {
      AvatarThumbnail {
        if job.isUnderWay {
          ProgressView().controlSize(.small)
        } else {
          Image(systemName: "exclamationmark.triangle").foregroundStyle(.red)
        }
      }
      VStack(alignment: .leading, spacing: 1) {
        Text(verbatim: Self.title(of: job))
          .fontWeight(.semibold)
          .lineLimit(1)
          .truncationMode(.tail)
        Group {
          switch job.phase {
          case .running:
            AlertSoundProgressText(sounds: sounds, job: job)
          case .failed(_, let at):
            Text(
              "Failed · \(at.formatted(AvatarLibraryPresentation.relative(locale)))",
              bundle: .module, comment: "A generation that failed, and when.")
          }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .lineLimit(1)
      }
      Spacer(minLength: 8)
      switch job.phase {
      case .running:
        Button {
          sounds.cancel()
        } label: {
          Text("Cancel", bundle: .module)
        }
        .controlSize(.small)
      case .failed:
        AvatarBadge(kind: .failed)
      }
    }
    .padding(.vertical, 4)
    .accessibilityElement(children: .combine)
    .accessibilityIdentifier("alert-sound-job-row")
  }

  /// What a composition is called before it is a sound: the first line of what was asked.
  static func title(of job: AlertSoundLibraryModel.Job) -> String {
    let line = job.request.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
    return DisplaySafeText.visible(line)
  }
}

/// "Codex is composing… 0:14".
struct AlertSoundProgressText: View {
  let sounds: AlertSoundLibraryModel
  let job: AlertSoundLibraryModel.Job

  var body: some View {
    TimelineView(.periodic(from: job.startedAt, by: 1)) { context in
      let elapsed = AvatarLibraryPresentation.elapsed(context.date.timeIntervalSince(job.startedAt))
      let agent = AlertSoundPresentation.agentName(job.provider.rawValue, in: sounds)
      if job.target == nil {
        Text(
          "\(agent) is composing… \(elapsed)", bundle: .module,
          comment: "While an agent composes a sound: the agent, then the time since it started.")
      } else {
        Text(
          "\(agent) is changing the sound… \(elapsed)", bundle: .module,
          comment: "While an agent changes a sound: the agent, then the time since it started.")
      }
    }
    .monospacedDigit()
  }
}

// MARK: - The card

/// "Create a Sound": the last row of the user's own sounds. Folded, a dashed line; unfolded, where
/// to describe the sound, the agent that composes it, and the way to import a file. Greyed out,
/// with the reason, while something is being made or the library is full.
struct NewAlertSoundCard: View {
  @Bindable var sounds: AlertSoundLibraryModel
  @Binding var isExpanded: Bool
  var isDescriptionFocused: FocusState<Bool>.Binding
  let chooseFile: () -> Void
  let generate: () -> Void

  var body: some View {
    let reason = unavailability
    let isOpen = isExpanded && reason == nil
    VStack(alignment: .leading, spacing: 0) {
      Button {
        isExpanded.toggle()
        if isExpanded { isDescriptionFocused.wrappedValue = true }
      } label: {
        HStack(spacing: 11) {
          Image(systemName: "plus")
            .font(.system(size: 22, weight: .light))
            .foregroundStyle(Color.accentColor)
            .frame(width: 46, height: 46)
            .background(RoundedRectangle(cornerRadius: 9).fill(Color.accentColor.opacity(0.12)))
          VStack(alignment: .leading, spacing: 1) {
            Text("Create a Sound", bundle: .module)
              .fontWeight(.semibold)
              .foregroundStyle(reason == nil ? Color.accentColor : Color.secondary)
            Group {
              if let reason {
                Text(reason)
              } else {
                Text("Describe it to an agent, or import a file", bundle: .module)
              }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
          }
          Spacer(minLength: 8)
          Image(systemName: isOpen ? "chevron.down" : "chevron.right")
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      .disabled(reason != nil)
      .accessibilityValue(
        isOpen ? Text("Unfolded", bundle: .module) : Text("Folded", bundle: .module)
      )
      .accessibilityIdentifier("alert-sound-create-card")
      if isOpen {
        Divider()
        form
          .padding(EdgeInsets(top: 10, leading: 12, bottom: 12, trailing: 12))
      }
    }
    .background(
      RoundedRectangle(cornerRadius: 9)
        .fill(isOpen ? AnyShapeStyle(.background.secondary) : AnyShapeStyle(.clear))
    )
    .overlay(
      RoundedRectangle(cornerRadius: 9)
        .strokeBorder(
          isOpen ? AnyShapeStyle(.separator) : AnyShapeStyle(.tertiary),
          style: StrokeStyle(lineWidth: isOpen ? 1 : 1.5, dash: isOpen ? [] : [5, 3]))
    )
    .opacity(reason == nil ? 1 : 0.6)
    .padding(.vertical, 6)
  }

  /// Why nothing new can be made now.
  private var unavailability: LocalizedStringResource? {
    if sounds.entries.count >= AlertSoundRules.maximumCount {
      return AlertSoundPresentation.message(for: .limitReached)
    }
    if !sounds.isIdle {
      return LocalizedStringResource(
        "One sound at a time: wait for the one being made.", bundle: .module)
    }
    return nil
  }

  private var form: some View {
    VStack(alignment: .leading, spacing: 10) {
      VStack(alignment: .leading, spacing: 4) {
        Text("Description", bundle: .module)
          .font(.callout.weight(.medium))
        ReplaceableTextEditor(text: $sounds.description)
          .font(.body)
          .frame(height: 58)
          .scrollContentBackground(.hidden)
          .padding(4)
          .background(RoundedRectangle(cornerRadius: 6).fill(.background))
          .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.separator))
          .focused(isDescriptionFocused)
          .accessibilityLabel(Text("Description", bundle: .module))
          .accessibilityIdentifier("alert-sound-description")
        Text(
          "A soft little chime, two rising notes… The agent writes the notes; Vibe Manager plays them.",
          bundle: .module
        )
        .font(.caption)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
      }
      VStack(alignment: .leading, spacing: 4) {
        if sounds.options.isEmpty {
          Text("No agent can compose a sound now.", bundle: .module)
            .font(.callout)
            .foregroundStyle(.secondary)
        } else {
          HStack(spacing: 8) {
            Text("Composed by", bundle: .module)
              .font(.callout.weight(.medium))
            Picker(selection: $sounds.selectedProvider) {
              ForEach(sounds.options) { option in
                Text(verbatim: option.descriptor.displayName).tag(Optional(option.id))
              }
            } label: {
              Text("Composed by", bundle: .module)
            }
            .labelsHidden()
            .fixedSize()
            Spacer(minLength: 0)
          }
          Text("The generation uses the account and the quota of this agent.", bundle: .module)
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
      }
      HStack {
        Button {
          chooseFile()
        } label: {
          Text("Import a File…", bundle: .module)
        }
        .accessibilityIdentifier("alert-sound-import")
        Spacer()
        Button {
          generate()
        } label: {
          Text("Generate", bundle: .module)
        }
        .buttonStyle(.borderedProminent)
        .disabled(!sounds.canGenerate)
        .accessibilityIdentifier("alert-sound-generate")
      }
    }
  }
}

// MARK: - Settings › Notifications

/// The alert sound, in Settings › Notifications: built as the avatar's row above it — the sound's
/// shape, a menu of the sounds, ▶ to hear it, and the way to the page that makes them.
struct AlertSoundInUseRow: View {
  let sounds: AlertSoundLibraryModel
  let manage: () -> Void

  private static let menuWidth: CGFloat = 200

  var body: some View {
    HStack(spacing: 12) {
      VStack(alignment: .leading, spacing: 2) {
        Text("Alert sound", bundle: .module)
        Self.explanation
          .font(.subheadline)
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      .accessibilityHidden(true)
      AlertSoundThumbnail(sounds: sounds, choice: sounds.inUse, size: 26)
        .padding(2)
        .background(RoundedRectangle(cornerRadius: 7).fill(.quaternary))
      Picker(selection: inUse) {
        ForEach([AlertSoundChoice.systemDefault, .none], id: \.self) { choice in
          Text(verbatim: AlertSoundPresentation.name(of: choice, in: sounds)).tag(choice)
        }
        if !sounds.entries.isEmpty {
          Section {
            ForEach(sounds.entries) { entry in
              Text(verbatim: DisplaySafeText.visible(entry.name)).tag(
                AlertSoundChoice.custom(entry.id))
            }
          } header: {
            Text("My Sounds", bundle: .module, comment: "The user's own alert sounds.")
          }
        }
        Section {
          ForEach(BundledAlertSound.allCases, id: \.self) { sound in
            Text(verbatim: AlertSoundPresentation.name(of: sound)).tag(
              AlertSoundChoice.bundled(sound.rawValue))
          }
        } header: {
          Text(verbatim: "Vibe Manager")
        }
        if !sounds.systemSounds.isEmpty {
          Section {
            ForEach(sounds.systemSounds, id: \.self) { name in
              Text(verbatim: name).tag(AlertSoundChoice.macOS(name))
            }
          } header: {
            Text(verbatim: "macOS")
          }
        }
      } label: {
        Text("Alert sound", bundle: .module)
      }
      .labelsHidden()
      .frame(maxWidth: Self.menuWidth)
      .fixedSize(horizontal: false, vertical: true)
      .layoutPriority(1)
      .accessibilityHint(Self.explanation)
      .accessibilityIdentifier("alert-sound-picker")
      Button {
        sounds.play(sounds.inUse)
      } label: {
        Image(systemName: "play.fill")
      }
      .disabled(sounds.inUse == .none)
      .accessibilityLabel(Text("Play the Alert Sound", bundle: .module))
      .instantTooltip(Text("Play the Alert Sound", bundle: .module))
      .accessibilityIdentifier("alert-sound-play")
      Button {
        manage()
      } label: {
        Text("Manage Sounds…", bundle: .module)
      }
      .fixedSize()
      .layoutPriority(1)
      .accessibilityIdentifier("manage-alert-sounds")
    }
  }

  private static var explanation: Text {
    Text(
      "When a session out of sight needs you. Others are made in Sounds.",
      bundle: .module)
  }

  /// Choosing a sound puts it in use, and plays it.
  var inUse: Binding<AlertSoundChoice> {
    Binding(
      get: { sounds.inUse },
      set: { choice in
        sounds.use(choice)
        sounds.play(choice)
      })
  }
}

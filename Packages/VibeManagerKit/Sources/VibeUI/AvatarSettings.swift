import AppKit
import SwiftUI
import UniformTypeIdentifiers
import VibeApplication

/// The floating panel, in Settings › Requests (#41).
struct FloatingPanelSettingsSection: View {
  @Bindable var panel: FloatingRequestPanelModel

  var body: some View {
    Section {
      Toggle(isOn: $panel.isEnabled) {
        Text("Show requests above other applications", bundle: .module)
        Text(
          "When Vibe Manager is not in front, an avatar presents the requests in a bubble. Notifications are then not needed.",
          bundle: .module)
      }
      .accessibilityIdentifier("floating-panel-toggle")
      Picker(selection: $panel.idle) {
        Text("Hide the panel", bundle: .module).tag(FloatingPanelIdle.hidden)
        Text("Keep the avatar on screen", bundle: .module).tag(FloatingPanelIdle.avatarOnly)
      } label: {
        Text("With no pending request", bundle: .module)
      }
      .disabled(!panel.isEnabled)
      LabeledContent {
        Text(verbatim: "⌃⌥⌘P")
          .monospaced()
      } label: {
        Text("Shortcut", bundle: .module)
        Text("Reaches the bubble from any application.", bundle: .module)
      }
      LabeledContent {
        Button {
          panel.resetPositions()
        } label: {
          Text("Put Back in Place", bundle: .module)
        }
      } label: {
        Text("Position", bundle: .module)
        Text("The avatar goes back to the bottom right corner of each screen.", bundle: .module)
      }
      .disabled(!panel.isEnabled)
    } header: {
      Text("Floating Panel", bundle: .module, comment: "A section of the Settings window.")
    }
  }
}

/// Settings › Avatar (#41): the avatar in use, and the one being made — described and generated
/// by an agent, or imported from an archive — with an animated preview before it is used.
struct AvatarSettings: View {
  @Bindable var studio: AvatarStudioModel
  @State private var isImporting = false
  @State private var isExporting = false
  @State private var exportDocument: AvatarArchiveDocument?
  @State private var includesDescription = true
  @State private var confirmsReset = false
  @State private var isDropTargeted = false

  var body: some View {
    Form {
      currentSection
      if let problem = studio.problem {
        Section {
          Label {
            Text(AvatarPresentation.message(for: problem))
              .fixedSize(horizontal: false, vertical: true)
          } icon: {
            Image(systemName: "exclamationmark.triangle.fill")
              .foregroundStyle(.orange)
          }
          .accessibilityIdentifier("avatar-problem")
        }
      }
      createSection
      if let candidate = studio.candidate {
        candidateSection(candidate)
      }
    }
    .formStyle(.grouped)
    .frame(width: SettingsView.formWidth)
    .frame(minHeight: 520)
    .task {
      await studio.refreshOptions()
    }
    .fileImporter(isPresented: $isImporting, allowedContentTypes: [.zip]) { result in
      guard case .success(let url) = result else { return }
      importArchive(at: url)
    }
    .fileExporter(
      isPresented: $isExporting, document: exportDocument, contentType: .zip,
      defaultFilename: studio.exportFileName
    ) { _ in
      exportDocument = nil
    }
    .confirmationDialog(
      Text("Go back to the default avatar?", bundle: .module), isPresented: $confirmsReset
    ) {
      Button(role: .destructive) {
        Task { await studio.resetToDefault() }
      } label: {
        Text("Use the Default Avatar", bundle: .module)
      }
    } message: {
      Text("Your avatar is deleted. Export it first to keep it.", bundle: .module)
    }
  }

  // MARK: - In use

  private var currentSection: some View {
    Section {
      HStack(alignment: .center, spacing: 16) {
        AvatarPreview(images: studio.currentImages)
          .dropDestination(for: URL.self) { urls, _ in
            guard let url = urls.first, url.pathExtension.lowercased() == "zip" else {
              return false
            }
            importArchive(at: url)
            return true
          } isTargeted: {
            isDropTargeted = $0
          }
          .overlay(
            RoundedRectangle(cornerRadius: 12)
              .strokeBorder(Color.accentColor, lineWidth: isDropTargeted ? 3 : 0))
        VStack(alignment: .leading, spacing: 8) {
          Text(verbatim: DisplaySafeText.visible(currentName))
            .font(.headline)
          HStack {
            Button {
              isImporting = true
            } label: {
              Text("Import…", bundle: .module)
            }
            .disabled(studio.work != nil || studio.isImporting)
            .accessibilityIdentifier("avatar-import")
            Button {
              exportDocument = studio.exportArchive(includingDescription: includesDescription)
                .map { AvatarArchiveDocument(data: $0) }
              isExporting = exportDocument != nil
            } label: {
              Text("Export…", bundle: .module)
            }
            .disabled(studio.current == nil)
          }
          Toggle(isOn: $includesDescription) {
            Text("Include the description in the export", bundle: .module)
          }
          .controlSize(.small)
          if studio.isCustom {
            Button {
              confirmsReset = true
            } label: {
              Text("Go Back to the Default Avatar", bundle: .module)
            }
          }
        }
      }
    } header: {
      Text("Avatar", bundle: .module, comment: "A section of the Settings window.")
    } footer: {
      Text(
        "A zip archive dropped on the avatar is imported. It holds one image per expression, named after it (neutral.png, pleased.png…).",
        bundle: .module
      )
      .font(.caption)
      .foregroundStyle(.secondary)
    }
  }

  private var currentName: String {
    guard studio.isCustom, let name = studio.current?.manifest.name, !name.isEmpty else {
      return String(
        localized: LocalizedStringResource(
          "Default avatar", bundle: .module, comment: "The avatar shipped with the application."))
    }
    return name
  }

  // MARK: - Making

  private var createSection: some View {
    Section {
      VStack(alignment: .leading, spacing: 4) {
        Text("Describe it", bundle: .module)
        TextEditor(text: $studio.description)
          .font(.body)
          .frame(height: 64)
          .scrollContentBackground(.hidden)
          .padding(4)
          .background(RoundedRectangle(cornerRadius: 6).fill(.background))
          .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.separator))
          .accessibilityLabel(Text("Describe it", bundle: .module))
          .accessibilityIdentifier("avatar-description")
        Text(
          "Its look only: the agent draws the same character in ten expressions.",
          bundle: .module
        )
        .font(.caption)
        .foregroundStyle(.secondary)
      }
      Picker(selection: $studio.selectedProvider) {
        ForEach(studio.options) { option in
          Group {
            if let reason = option.unavailability {
              Text(
                verbatim:
                  "\(option.descriptor.displayName) — \(String(localized: AvatarPresentation.reason(reason)))"
              )
            } else {
              Text(verbatim: option.descriptor.displayName)
            }
          }
          .tag(Optional(option.id))
          .selectionDisabled(option.unavailability != nil)
        }
      } label: {
        Text("Drawn by", bundle: .module)
        Text("The generation uses the account and the quota of this agent.", bundle: .module)
      }
      .disabled(studio.work != nil)
      HStack {
        if let work = studio.work {
          ProgressView().controlSize(.small)
          TimelineView(.periodic(from: work.startedAt, by: 1)) { context in
            Text(
              progressText(work.kind, elapsed: context.date.timeIntervalSince(work.startedAt))
            )
            .monospacedDigit()
            .foregroundStyle(.secondary)
          }
          Spacer()
          Button {
            studio.cancel()
          } label: {
            Text("Cancel", bundle: .module)
          }
        } else {
          Spacer()
          Button {
            studio.generate()
          } label: {
            Text("Generate", bundle: .module)
          }
          .buttonStyle(.borderedProminent)
          .disabled(!studio.canGenerate)
          .accessibilityIdentifier("avatar-generate")
        }
      }
    } header: {
      Text("Create My Avatar", bundle: .module, comment: "A section of the Settings window.")
    }
  }

  private func progressText(_ work: AvatarStudioModel.Work, elapsed: TimeInterval) -> String {
    let duration = Duration.seconds(Int(elapsed)).formatted(.units(allowed: [.minutes, .seconds]))
    switch work {
    case .wholeSet:
      return String(
        localized: LocalizedStringResource(
          "Generating the avatar… \(duration)", bundle: .module,
          comment: "While an agent draws an avatar. The time since it started."))
    case .expression(let expression):
      return String(
        localized: LocalizedStringResource(
          "Generating “\(AvatarPresentation.name(expression))”… \(duration)", bundle: .module,
          comment: "While an agent draws one expression again. The time since it started."))
    }
  }

  // MARK: - Candidate

  private func candidateSection(_ candidate: AvatarSpriteSet) -> some View {
    Section {
      HStack(alignment: .top, spacing: 16) {
        AvatarPreview(images: studio.candidateImages)
        LazyVGrid(
          columns: Array(repeating: GridItem(.fixed(64), spacing: 8), count: 5), spacing: 8
        ) {
          ForEach(AvatarExpression.allCases, id: \.self) { expression in
            expressionTile(expression)
          }
        }
      }
      if studio.ignoredFiles > 0 {
        Text(
          "\(studio.ignoredFiles) files of the archive were ignored: they are no expression's.",
          bundle: .module
        )
        .font(.caption)
        .foregroundStyle(.secondary)
      }
      if !candidate.isComplete {
        Text(
          "Expressions are missing: generate them before using this avatar.", bundle: .module
        )
        .font(.caption)
        .foregroundStyle(.orange)
      }
      HStack {
        if !(studio.candidate?.manifest.description ?? "").isEmpty {
          Button {
            if let description = studio.candidate?.manifest.description {
              studio.description = description
            }
            studio.generate()
          } label: {
            Text("Generate Everything Again", bundle: .module)
          }
          .disabled(studio.work != nil || studio.selectedGenerator == nil)
        }
        Spacer()
        Button {
          studio.discard()
        } label: {
          Text("Discard", bundle: .module)
        }
        Button {
          Task { await studio.accept() }
        } label: {
          Text("Use This Avatar", bundle: .module)
        }
        .buttonStyle(.borderedProminent)
        .disabled(!candidate.isComplete || studio.work != nil)
        .accessibilityIdentifier("avatar-accept")
      }
    } header: {
      Text("Preview", bundle: .module, comment: "A section of the Settings window.")
    }
  }

  private func expressionTile(_ expression: AvatarExpression) -> some View {
    let image = studio.candidateImages[expression]
    return VStack(spacing: 2) {
      ZStack {
        RoundedRectangle(cornerRadius: 8).fill(.quaternary)
        if let image {
          Image(nsImage: image).resizable().aspectRatio(contentMode: .fit).padding(2)
        } else {
          Image(systemName: "questionmark.dashed").foregroundStyle(.secondary)
        }
      }
      .frame(width: 64, height: 64)
      .overlay(alignment: .topTrailing) {
        Button {
          studio.regenerate(expression)
        } label: {
          Image(systemName: image == nil ? "plus.circle.fill" : "arrow.clockwise.circle.fill")
            .symbolRenderingMode(.hierarchical)
        }
        .buttonStyle(.borderless)
        .disabled(studio.work != nil || studio.selectedGenerator == nil)
        .help(
          image == nil
            ? Text("Generate this expression", bundle: .module)
            : Text("Generate this expression again", bundle: .module)
        )
        .accessibilityLabel(
          image == nil
            ? Text("Generate \(AvatarPresentation.name(expression))", bundle: .module)
            : Text("Generate \(AvatarPresentation.name(expression)) again", bundle: .module))
      }
      Text(AvatarPresentation.name(of: expression))
        .font(.caption2)
        .foregroundStyle(image == nil ? .orange : .secondary)
        .lineLimit(1)
        .minimumScaleFactor(0.8)
    }
    .accessibilityElement(children: .contain)
  }

  // MARK: - Files

  private func importArchive(at url: URL) {
    let scoped = url.startAccessingSecurityScopedResource()
    defer { if scoped { url.stopAccessingSecurityScopedResource() } }
    // Read with the same bound as the archive itself: a larger file is not read at all.
    guard let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize else {
      studio.reject(.archiveUnreadable)
      return
    }
    guard size <= 30 * 1024 * 1024 else {
      studio.reject(.archiveTooLarge)
      return
    }
    guard let data = try? Data(contentsOf: url) else {
      studio.reject(.archiveUnreadable)
      return
    }
    Task { await studio.importArchive(data) }
  }
}

/// An avatar, animated in a loop: at rest, a request arriving, speech, an answer.
struct AvatarPreview: View {
  let images: [AvatarExpression: NSImage]
  @State private var animator = AvatarAnimator()
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  var body: some View {
    AvatarView(images: images, expression: animator.expression, size: 112)
      .padding(8)
      .background(RoundedRectangle(cornerRadius: 12).fill(.quaternary))
      .task {
        animator.reducesMotion = reduceMotion
        animator.start()
        defer { animator.stop() }
        while !Task.isCancelled {
          animator.send(.requestArrived(speech: "Refacto API: shell command swift test"))
          try? await Task.sleep(for: .seconds(4))
          animator.send(.answerSending)
          try? await Task.sleep(for: .seconds(1))
          animator.send(.answerSucceeded(next: nil))
          try? await Task.sleep(for: .seconds(6))
        }
      }
      .accessibilityElement()
      .accessibilityLabel(Text("Animated preview of the avatar", bundle: .module))
  }
}

/// The archive of an avatar, for the save panel.
struct AvatarArchiveDocument: FileDocument {
  static let readableContentTypes: [UTType] = [.zip]
  let data: Data

  init(data: Data) {
    self.data = data
  }

  init(configuration: ReadConfiguration) throws {
    data = configuration.file.regularFileContents ?? Data()
  }

  func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
    FileWrapper(regularFileWithContents: data)
  }
}

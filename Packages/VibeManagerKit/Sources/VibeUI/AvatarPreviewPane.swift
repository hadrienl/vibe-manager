import AppKit
import SwiftUI
import VibeApplication

/// The preview of Settings › Requests › Avatars (#154): the avatar selected in its role — animated
/// beside a request's bubble — its name, where it comes from, what can be done with it, and its
/// ten expressions, each drawn again with ↻, or drawn at last with + when it lacks one.
extension AvatarLibraryView {
  var preview: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 10) {
        Text("Preview", bundle: .module).font(.headline)
        switch avatars.selection {
        case .job(let id):
          if let job = avatars.job(id) {
            jobPreview(job)
          }
        case .avatar:
          if let entry = avatars.selectedEntry {
            avatarPreview(entry)
          }
        case nil:
          AvatarStage { EmptyView() }
        }
      }
      .padding(EdgeInsets(top: 14, leading: 20, bottom: 12, trailing: 20))
      .frame(maxWidth: .infinity, alignment: .leading)
    }
    // Scrolls only if a long message would push the expressions out of the page.
    .scrollBounceBehavior(.basedOnSize)
    .accessibilityIdentifier("avatar-preview")
  }

  // MARK: - An avatar

  @ViewBuilder
  private func avatarPreview(_ entry: AvatarLibraryEntry) -> some View {
    let name = DisplaySafeText.visible(AvatarLibraryModel.name(of: entry))
    AvatarStage {
      if avatars.selectedAvatar != nil {
        DemoBubble()
        AvatarPreview(images: avatars.selectedImages)
      } else if entry.problem == .unreadable {
        FailureMark()
      }
    }
    VStack(alignment: .leading, spacing: 2) {
      HStack(spacing: 8) {
        Group {
          if entry.id == .default {
            Text(AvatarLibraryRules.defaultAvatarTitle)
          } else {
            Text(verbatim: name)
          }
        }
        .font(.title3.weight(.semibold))
        .lineLimit(1)
        .truncationMode(.middle)
        .help(Text(verbatim: name))
        Spacer(minLength: 4)
        if entry.isDraft {
          AvatarBadge(kind: .toCheck)
        } else if entry.id == avatars.inUse {
          AvatarBadge(kind: .inUse)
        }
      }
      AvatarLibraryPresentation.origin(of: entry, avatars: avatars, locale: locale)
        .font(.caption)
        .foregroundStyle(.secondary)
        .lineLimit(1)
    }
    if let description = entry.manifest?.description, !description.isEmpty {
      Text("“\(DisplaySafeText.visible(description))”", bundle: .module)
        .font(.caption)
        .foregroundStyle(.secondary)
        .lineLimit(3)
        .help(Text(verbatim: description))
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 6).fill(.quaternary.opacity(0.6)))
    }
    if entry.isDraft {
      draftControls(entry)
    } else {
      keptControls(entry)
    }
    if let problem = avatars.problem, problem != .writing {
      problemLabel(Text(AvatarPresentation.message(for: problem)))
    }
    if let work = avatars.work, work.avatar == entry.id || work.origin == entry.id {
      HStack(spacing: 8) {
        ProgressView().controlSize(.small)
        AvatarProgressText(avatars: avatars, job: work)
          .font(.caption)
          .foregroundStyle(.secondary)
          .lineLimit(1)
        Spacer(minLength: 4)
        if work.phase == .running {
          Button {
            avatars.cancel()
          } label: {
            Text("Cancel", bundle: .module)
          }
          .controlSize(.small)
        }
      }
    }
    expressions(entry)
  }

  /// "Use This Avatar", "Export…" and the menu •••: an avatar kept, or the default one.
  @ViewBuilder
  private func keptControls(_ entry: AvatarLibraryEntry) -> some View {
    switch entry.problem {
    case .unreadable:
      problemLabel(
        Text(
          "This avatar cannot be read: delete it, or import it again.", bundle: .module))
    case .incomplete(let missing):
      problemLabel(
        Text(
          "This avatar lacks \(missing.count) expressions: complete it to use it.",
          bundle: .module))
    case nil:
      EmptyView()
    }
    HStack(spacing: 6) {
      if case .incomplete = entry.problem {
        Button {
          Task { await avatars.completeDraft(of: entry.id) }
        } label: {
          Text("Complete It", bundle: .module, comment: "Makes a draft to complete an avatar.")
        }
        .buttonStyle(.borderedProminent)
        .disabled(!avatars.isIdle)
      } else if entry.problem == nil {
        Button {
          Task { await avatars.use(entry.id) }
        } label: {
          if entry.id == avatars.inUse {
            Label {
              Text("In Use", bundle: .module, comment: "The avatar of the floating panel.")
            } icon: {
              Image(systemName: "checkmark")
            }
          } else {
            Text("Use This Avatar", bundle: .module)
          }
        }
        .buttonStyle(.borderedProminent)
        .disabled(entry.id == avatars.inUse)
        .accessibilityIdentifier("avatar-use")
        Button {
          export(entry.id, includingDescription: true)
        } label: {
          Text("Export…", bundle: .module)
        }
      }
      Spacer(minLength: 4)
      SwiftUI.Menu {
        menuItems(for: entry)
      } label: {
        Image(systemName: "ellipsis")
      }
      .menuIndicator(.hidden)
      .fixedSize()
      .help(Text("More Actions", bundle: .module))
      .accessibilityLabel(Text("More Actions", bundle: .module))
      .accessibilityIdentifier("avatar-menu")
    }
  }

  /// What is decided about a draft: draw it all again, discard it, or keep it — in the floating
  /// panel too when the box says so.
  @ViewBuilder
  private func draftControls(_ entry: AvatarLibraryEntry) -> some View {
    let isComplete = avatars.selectedAvatar?.isComplete ?? false
    HStack(spacing: 6) {
      if !(entry.manifest?.description ?? "").isEmpty {
        Button {
          // What is drawn now is replaced: asked first.
          confirming = .redrawAll(entry.id)
        } label: {
          Text("Draw Everything Again", bundle: .module)
        }
        .disabled(!avatars.isIdle || avatars.selectedGenerator == nil)
      }
      Spacer(minLength: 4)
      Button {
        deleting = entry.id
      } label: {
        Text("Discard", bundle: .module)
      }
      Button {
        Task { await avatars.keep(entry.id) }
      } label: {
        Text("Keep", bundle: .module, comment: "Keeps an avatar just made in the library.")
      }
      .buttonStyle(.borderedProminent)
      .disabled(!isComplete || !avatars.canKeep(entry.id))
      .accessibilityIdentifier("avatar-keep")
    }
    Toggle(isOn: $avatars.usesKeptDraft) {
      Text("Use it in the floating panel", bundle: .module)
    }
    .accessibilityIdentifier("avatar-use-kept")
    if let missing = avatars.selectedAvatar?.missingExpressions, !missing.isEmpty {
      Group {
        if missing.count == 1, let expression = missing.first {
          Text(
            "“\(Text(AvatarPresentation.name(of: expression)))” is missing: draw it with + before keeping this avatar.",
            bundle: .module)
        } else {
          Text(
            "\(missing.count) expressions are missing: draw them with + before keeping this avatar.",
            bundle: .module)
        }
      }
      .font(.caption)
      .foregroundStyle(.orange)
      .fixedSize(horizontal: false, vertical: true)
    }
    if let ignored = avatars.ignoredFiles, ignored.draft == entry.id {
      Text(
        "\(ignored.count) files of the archive were ignored: they are no expression's.",
        bundle: .module
      )
      .font(.caption)
      .foregroundStyle(.secondary)
      .fixedSize(horizontal: false, vertical: true)
    }
  }

  // MARK: - A generation

  @ViewBuilder
  private func jobPreview(_ job: AvatarLibraryModel.Job) -> some View {
    let agent = AvatarLibraryPresentation.agentName(job.provider.rawValue, avatars: avatars)
    AvatarStage {
      if job.isUnderWay {
        VStack(spacing: 6) {
          Circle()
            .strokeBorder(.tertiary, style: StrokeStyle(lineWidth: 2, dash: [5, 4]))
            .frame(width: 96, height: 96)
            .overlay(ProgressView().controlSize(.small))
          VStack(spacing: 2) {
            Text("\(agent) is drawing ten expressions", bundle: .module)
              .fontWeight(.semibold)
            Text(
              "Usually one to two minutes. You can close Settings: the generation goes on.",
              bundle: .module
            )
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
          }
          .font(.caption)
          .multilineTextAlignment(.center)
          ProgressView()
            .progressViewStyle(.linear)
            .frame(width: 190)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
      } else {
        FailureMark()
      }
    }
    VStack(alignment: .leading, spacing: 2) {
      HStack(spacing: 8) {
        AvatarLibraryPresentation.name(of: job)
          .font(.title3.weight(.semibold))
          .lineLimit(1)
          .truncationMode(.middle)
        Spacer(minLength: 4)
        AvatarBadge(kind: job.isUnderWay ? .running : .failed)
      }
      Group {
        switch job.phase {
        case .running, .writing:
          TimelineView(.periodic(from: job.startedAt, by: 1)) { context in
            Text(
              "Generation started \(AvatarLibraryPresentation.elapsed(context.date.timeIntervalSince(job.startedAt))) ago",
              bundle: .module, comment: "Under the name of an avatar being drawn: for how long.")
          }
          .monospacedDigit()
        case .failed(_, let at), .unsaved(let at):
          Text(
            "Drawn by \(agent) · \(at.formatted(AvatarLibraryPresentation.relative(locale)))",
            bundle: .module,
            comment: "Where an avatar comes from: the agent that drew it, and when.")
        }
      }
      .font(.caption)
      .foregroundStyle(.secondary)
      .lineLimit(1)
    }
    switch job.phase {
    case .running, .writing:
      HStack {
        Spacer()
        Button {
          avatars.cancel()
        } label: {
          Text("Cancel", bundle: .module)
        }
        .disabled(job.phase != .running)
      }
    case .failed(let error, _):
      errorBox(Text(AvatarPresentation.message(for: .generation(error))))
      HStack(spacing: 6) {
        Button {
          reviseDescription(of: job.id)
        } label: {
          Text("Edit the Description…", bundle: .module)
        }
        .disabled(!avatars.isIdle)
        Spacer(minLength: 4)
        Button {
          Task { await avatars.dismiss(job.id) }
        } label: {
          Text("Remove", bundle: .module)
        }
        Button {
          avatars.retry(job.id)
        } label: {
          Text("Try Again", bundle: .module)
        }
        .buttonStyle(.borderedProminent)
        .disabled(!avatars.canStartCreation)
        .accessibilityIdentifier("avatar-retry")
      }
    case .unsaved:
      errorBox(Text(AvatarPresentation.message(for: .writing)))
      HStack(spacing: 6) {
        Spacer()
        Button {
          // What was drawn is lost with it: asked first.
          confirming = .removeUnsaved(job.id)
        } label: {
          Text("Remove", bundle: .module)
        }
        Button {
          Task { await avatars.retrySaving(job.id) }
        } label: {
          Text("Save Again", bundle: .module, comment: "Writes a generated avatar again.")
        }
        .buttonStyle(.borderedProminent)
        .disabled(avatars.work != nil)
      }
    }
    emptyExpressions
  }

  // MARK: - Expressions

  private func expressions(_ entry: AvatarLibraryEntry) -> some View {
    let missing = AvatarExpression.allCases.filter { avatars.selectedImages[$0] == nil }
    let redraws = AvatarLibraryPresentation.canRedraw(entry)
    return VStack(alignment: .leading, spacing: 6) {
      HStack {
        Text("Expressions", bundle: .module)
        Spacer()
        if avatars.selectedAvatar != nil, !missing.isEmpty {
          Text("\(missing.count) expressions missing", bundle: .module)
            .foregroundStyle(.orange)
        } else if redraws {
          Text("↻ to draw one again", bundle: .module)
        }
      }
      .font(.caption)
      .foregroundStyle(.secondary)
      Self.expressionGrid { expression in
        ExpressionTile(
          expression: expression, image: avatars.selectedImages[expression],
          isLoaded: avatars.selectedAvatar != nil, redraws: redraws,
          isEnabled: avatars.canRegenerate
        ) {
          avatars.regenerate(expression)
        }
      }
    }
  }

  private var emptyExpressions: some View {
    VStack(alignment: .leading, spacing: 6) {
      Text("Expressions", bundle: .module)
        .font(.caption)
        .foregroundStyle(.secondary)
      Self.expressionGrid { expression in
        ExpressionTile(
          expression: expression, image: nil, isLoaded: false, redraws: false, isEnabled: false
        ) {}
      }
    }
  }

  /// The ten expressions, five by row, aligned on the top of their tiles: a name on three lines
  /// does not move its tile down.
  private static func expressionGrid<Tile: View>(
    @ViewBuilder _ tile: @escaping (AvatarExpression) -> Tile
  ) -> some View {
    let rows = [
      Array(AvatarExpression.allCases.prefix(5)), Array(AvatarExpression.allCases.dropFirst(5)),
    ]
    return Grid(alignment: .top, horizontalSpacing: 6, verticalSpacing: 6) {
      ForEach(rows.indices, id: \.self) { row in
        GridRow(alignment: .top) {
          ForEach(rows[row], id: \.self) { expression in
            tile(expression)
          }
        }
      }
    }
  }

  // MARK: - Messages

  private func problemLabel(_ text: Text) -> some View {
    Label {
      text
        .fixedSize(horizontal: false, vertical: true)
    } icon: {
      Image(systemName: "exclamationmark.triangle.fill")
        .foregroundStyle(.orange)
    }
    .font(.callout)
    .accessibilityIdentifier("avatar-problem")
  }

  private func errorBox(_ text: Text) -> some View {
    Label {
      text
        .fixedSize(horizontal: false, vertical: true)
    } icon: {
      Image(systemName: "exclamationmark.triangle.fill")
        .foregroundStyle(.red)
    }
    .font(.callout)
    .padding(.horizontal, 10)
    .padding(.vertical, 8)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(RoundedRectangle(cornerRadius: 8).fill(Color.red.opacity(0.12)))
    .accessibilityIdentifier("avatar-failure")
  }
}

extension AvatarLibraryPresentation {
  /// Whether the expressions of an avatar can be drawn again: a draft, or a kept avatar that says
  /// what it looks like, or lacks expressions. Never the default one, which has no description.
  static func canRedraw(_ entry: AvatarLibraryEntry) -> Bool {
    guard entry.id != .default, entry.problem != .unreadable else { return false }
    if entry.isDraft { return true }
    if case .incomplete = entry.problem { return true }
    return !(entry.manifest?.description ?? "").isEmpty
  }
}

/// The scene of the preview: where the avatar plays its role.
struct AvatarStage<Content: View>: View {
  @ViewBuilder let content: Content

  var body: some View {
    ZStack {
      RoundedRectangle(cornerRadius: 12)
        .fill(.quaternary)
      content
    }
    .frame(maxWidth: .infinity)
    .frame(height: 188)
  }
}

/// A request's bubble, as the floating panel shows one, for the avatar to present. Decorative.
struct DemoBubble: View {
  var body: some View {
    VStack(alignment: .leading, spacing: 3) {
      Text(verbatim: "Refacto API")
        .font(.caption.weight(.semibold))
      Text(verbatim: "swift test")
        .font(.caption.monospaced())
        .foregroundStyle(.secondary)
      HStack(spacing: 5) {
        Text("Allow", bundle: .module)
          .foregroundStyle(.white)
          .padding(.horizontal, 7)
          .padding(.vertical, 1)
          .background(RoundedRectangle(cornerRadius: 4).fill(Color.accentColor))
        Text("Deny", bundle: .module)
          .padding(.horizontal, 7)
          .padding(.vertical, 1)
          .background(RoundedRectangle(cornerRadius: 4).fill(.quaternary))
      }
      .font(.caption2)
      .padding(.top, 3)
    }
    .padding(.horizontal, 10)
    .padding(.vertical, 8)
    .frame(width: 170, alignment: .leading)
    .background(
      RoundedRectangle(cornerRadius: 12)
        .fill(.background)
        .shadow(color: .black.opacity(0.14), radius: 7, y: 3)
    )
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    .padding(14)
    .accessibilityHidden(true)
  }
}

/// A generation that failed, on the stage.
struct FailureMark: View {
  var body: some View {
    Circle()
      .strokeBorder(Color.red, style: StrokeStyle(lineWidth: 2, dash: [5, 4]))
      .frame(width: 72, height: 72)
      .overlay(
        Image(systemName: "exclamationmark")
          .font(.system(size: 28, weight: .semibold))
          .foregroundStyle(.red)
      )
      .accessibilityHidden(true)
  }
}

/// An avatar, animated in a loop: at rest, a request arriving, speech, an answer.
struct AvatarPreview: View {
  let images: [AvatarExpression: NSImage]
  var size: CGFloat = 124
  @State private var animator = AvatarAnimator()
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  var body: some View {
    AvatarView(images: images, expression: animator.expression, size: size)
      .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
      .padding(.trailing, 14)
      .padding(.bottom, 6)
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

/// One expression of the avatar selected, and the button that draws it again — or at last.
struct ExpressionTile: View {
  let expression: AvatarExpression
  let image: NSImage?
  /// Whether the avatar is read: an expression it lacks is then missing, not waiting.
  let isLoaded: Bool
  /// Whether its expressions can be drawn again at all.
  let redraws: Bool
  /// Whether one can be drawn now.
  let isEnabled: Bool
  let draw: () -> Void

  var body: some View {
    let isMissing = isLoaded && image == nil
    VStack(spacing: 2) {
      ZStack {
        RoundedRectangle(cornerRadius: 7)
          .fill(isMissing ? AnyShapeStyle(Color.orange.opacity(0.15)) : AnyShapeStyle(.quaternary))
        if let image {
          Image(nsImage: image).resizable().interpolation(.high).aspectRatio(contentMode: .fit)
            .padding(2)
        } else if isMissing {
          Image(systemName: "questionmark").foregroundStyle(.orange)
        } else {
          Circle()
            .strokeBorder(.tertiary, style: StrokeStyle(lineWidth: 1.5, dash: [3, 3]))
            .frame(width: 18, height: 18)
        }
      }
      // The picture says nothing the name below does not: VoiceOver reads the name.
      .accessibilityHidden(true)
      .overlay {
        if isMissing {
          RoundedRectangle(cornerRadius: 7).strokeBorder(Color.orange, lineWidth: 1.5)
        }
      }
      .frame(width: 46, height: 46)
      .overlay(alignment: .topTrailing) {
        if redraws, isLoaded {
          Button {
            draw()
          } label: {
            Image(systemName: image == nil ? "plus" : "arrow.clockwise")
              .font(.system(size: 9, weight: .bold))
              .foregroundStyle(isEnabled ? Color.accentColor : Color.secondary)
              .frame(width: 17, height: 17)
              .background(
                Circle()
                  .fill(.background)
                  .shadow(color: .black.opacity(0.25), radius: 1, y: 0.5)
              )
              .contentShape(Circle())
          }
          .buttonStyle(.plain)
          .offset(x: 5, y: -5)
          .disabled(!isEnabled)
          .help(
            image == nil
              ? Text("Generate this expression", bundle: .module)
              : Text("Generate this expression again", bundle: .module)
          )
          .accessibilityLabel(
            image == nil
              ? Text("Generate \(Text(AvatarPresentation.name(of: expression)))", bundle: .module)
              : Text(
                "Generate \(Text(AvatarPresentation.name(of: expression))) again", bundle: .module))
        }
      }
      // On two lines: "Mouth half open" is whole, in French too.
      Text(AvatarPresentation.name(of: expression))
        .font(.caption2)
        .foregroundStyle(isMissing ? .orange : .secondary)
        .multilineTextAlignment(.center)
        // Whole, at the size of the others: "Bouche grande ouverte" takes a third line.
        .lineLimit(3)
        .fixedSize(horizontal: false, vertical: true)
        // "missing" in words, not in orange alone.
        .accessibilityLabel(
          Text(
            verbatim: AvatarLibraryPresentation.spokenExpression(expression, isMissing: isMissing)))
    }
    .frame(maxWidth: .infinity)
    .accessibilityElement(children: .contain)
  }
}

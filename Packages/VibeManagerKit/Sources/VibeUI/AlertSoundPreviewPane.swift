import AppKit
import SwiftUI
import VibeApplication
import VibeConversationUI

/// The preview of Settings › Notifications › Sounds (#393): the sound selected in its role — its
/// shape, ▶, under a notification of example — its name, where it comes from, what can be done
/// with it, and, for a sound an agent composed, the change to ask and its versions, as the themes'
/// workshop does.
struct AlertSoundPreviewPane: View {
  @Bindable var sounds: AlertSoundLibraryModel
  let export: (AlertSoundID) -> Void
  let rename: (AlertSoundID) -> Void
  let delete: (AlertSoundID) -> Void
  @Environment(\.locale) private var locale

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 10) {
        Text("Preview", bundle: .module).font(.headline)
        switch sounds.selection {
        case .job(let id):
          if let job = sounds.job(id) { jobPreview(job) }
        case .sound(let choice):
          soundPreview(choice)
        case nil:
          stage { EmptyView() }
        }
      }
      .padding(EdgeInsets(top: 14, leading: 20, bottom: 12, trailing: 20))
      .frame(maxWidth: .infinity, alignment: .leading)
    }
    .scrollBounceBehavior(.basedOnSize)
    .accessibilityIdentifier("alert-sound-preview")
  }

  // MARK: - A sound

  @ViewBuilder
  private func soundPreview(_ choice: AlertSoundChoice) -> some View {
    let name = AlertSoundPresentation.name(of: choice, in: sounds)
    stage {
      VStack(spacing: 14) {
        HStack(spacing: 12) {
          Button {
            sounds.play(choice)
          } label: {
            Image(systemName: choice == .none ? "speaker.slash.fill" : "play.fill")
              .font(.system(size: 15, weight: .semibold))
              .foregroundStyle(.white)
              .frame(width: 40, height: 40)
              .background(Circle().fill(choice == .none ? Color.secondary : Color.accentColor))
          }
          .buttonStyle(.plain)
          .disabled(choice == .none)
          .accessibilityLabel(Text("Play “\(name)”", bundle: .module))
          .accessibilityIdentifier("alert-sound-preview-play")
          if let outline = sounds.outlines[choice] {
            AlertSoundOutline(values: outline, barWidth: 2.5, spacing: 2)
              .frame(height: 52)
          } else {
            Image(systemName: choice == .none ? "speaker.slash" : "speaker.wave.2")
              .font(.title2)
              .foregroundStyle(.secondary)
              .frame(maxWidth: .infinity, minHeight: 52)
          }
          if let duration = sounds.durations[choice] {
            Text(verbatim: AlertSoundPresentation.duration(duration, locale: locale))
              .font(.caption)
              .monospacedDigit()
              .foregroundStyle(.secondary)
          }
        }
        DemoNotification()
      }
      .padding(16)
    }
    VStack(alignment: .leading, spacing: 2) {
      HStack(spacing: 8) {
        Text(verbatim: name)
          .font(.title3.weight(.semibold))
          .lineLimit(1)
          .truncationMode(.middle)
          .instantTooltip(Text(verbatim: name))
        Spacer(minLength: 4)
        if choice == sounds.inUse { AvatarBadge(kind: .inUse) }
      }
      Text(verbatim: AlertSoundPresentation.origin(of: choice, in: sounds))
        .font(.caption)
        .foregroundStyle(.secondary)
        .lineLimit(1)
    }
    if case .custom(let id) = choice, let entry = sounds.entry(id),
      let description = entry.description
    {
      Text("“\(DisplaySafeText.visible(description))”", bundle: .module)
        .font(.caption)
        .foregroundStyle(.secondary)
        .lineLimit(3)
        .instantTooltip(Text(verbatim: description))
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 6).fill(.quaternary.opacity(0.6)))
    }
    controls(choice)
    if let problem = sounds.problem, !isAlert(problem) {
      problemLabel(Text(AlertSoundPresentation.message(for: problem)))
    }
    if case .custom(let id) = choice, let entry = sounds.entry(id), entry.recipe != nil {
      changeForm(entry)
      versions(of: id)
    }
  }

  /// "Use This Sound", "Export…" and the menu •••.
  private func controls(_ choice: AlertSoundChoice) -> some View {
    HStack(spacing: 6) {
      Button {
        sounds.use(choice)
      } label: {
        if choice == sounds.inUse {
          Label {
            Text("In Use", bundle: .module, comment: "The alert sound.")
          } icon: {
            Image(systemName: "checkmark")
          }
        } else {
          Text("Use This Sound", bundle: .module)
        }
      }
      .buttonStyle(.borderedProminent)
      .disabled(choice == sounds.inUse)
      .accessibilityIdentifier("alert-sound-use")
      if case .custom(let id) = choice {
        Button {
          export(id)
        } label: {
          Text("Export…", bundle: .module)
        }
        Spacer(minLength: 4)
        SwiftUI.Menu {
          Button {
            rename(id)
          } label: {
            Text("Rename…", bundle: .module)
          }
          Divider()
          Button(role: .destructive) {
            delete(id)
          } label: {
            Text("Delete…", bundle: .module)
          }
        } label: {
          Image(systemName: "ellipsis")
        }
        .menuIndicator(.hidden)
        .fixedSize()
        .instantTooltip(Text("More Actions", bundle: .module))
        .accessibilityLabel(Text("More Actions", bundle: .module))
      }
    }
  }

  // MARK: - Changing

  @ViewBuilder
  private func changeForm(_ entry: AlertSoundEntry) -> some View {
    VStack(alignment: .leading, spacing: 4) {
      Text("What should change?", bundle: .module)
        .font(.callout.weight(.medium))
        .padding(.top, 6)
      ReplaceableTextEditor(text: $sounds.change)
        .font(.body)
        .frame(height: 44)
        .scrollContentBackground(.hidden)
        .padding(4)
        .background(RoundedRectangle(cornerRadius: 6).fill(.background))
        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.separator))
        .overlay(alignment: .topLeading) {
          if sounds.change.isEmpty {
            Text("Lower, shorter, one more note…", bundle: .module)
              .foregroundStyle(.tertiary)
              .padding(.horizontal, 9)
              .padding(.vertical, 4)
              .allowsHitTesting(false)
          }
        }
        .accessibilityLabel(Text("What should change?", bundle: .module))
        .accessibilityIdentifier("alert-sound-change")
      if let work = sounds.work, work.target == entry.id {
        HStack(spacing: 8) {
          ProgressView().controlSize(.small)
          AlertSoundProgressText(sounds: sounds, job: work)
            .font(.caption)
            .foregroundStyle(.secondary)
            .lineLimit(1)
          Spacer(minLength: 4)
          Button {
            sounds.cancel()
          } label: {
            Text("Cancel", bundle: .module)
          }
          .controlSize(.small)
        }
      } else {
        HStack {
          Spacer()
          Button {
            sounds.generateChange()
          } label: {
            if let agent = agentName {
              Text("Change with \(agent)", bundle: .module)
            } else {
              Text("Change", bundle: .module)
            }
          }
          .disabled(!sounds.canChange)
          .accessibilityIdentifier("alert-sound-change-button")
        }
      }
    }
  }

  private var agentName: String? {
    sounds.options.first { $0.id == sounds.selectedProvider }?.descriptor.displayName
  }

  /// The versions made during this run, newest first: each heard with ▶, and put back.
  @ViewBuilder
  private func versions(of id: AlertSoundID) -> some View {
    let versions = sounds.versions[id] ?? []
    if versions.count > 1 {
      Text("Versions", bundle: .module)
        .font(.callout.weight(.medium))
        .padding(.top, 6)
      VStack(spacing: 2) {
        ForEach(versions.reversed()) { version in
          let isCurrent = sounds.currentVersion[id] == version.id
          HStack(spacing: 8) {
            Button {
              sounds.play(version)
            } label: {
              Image(systemName: "play.fill").font(.caption)
            }
            .buttonStyle(.borderless)
            .accessibilityLabel(Text("Play this version", bundle: .module))
            Text(verbatim: DisplaySafeText.visible(version.request))
              .font(.caption)
              .lineLimit(1)
              .truncationMode(.tail)
              .frame(maxWidth: .infinity, alignment: .leading)
            if isCurrent {
              Text("current", bundle: .module, comment: "The version a composed sound plays now.")
                .font(.caption2)
                .foregroundStyle(.secondary)
            } else {
              Button {
                Task { await sounds.restore(version, of: id) }
              } label: {
                Text("Put Back", bundle: .module, comment: "Makes a sound play an earlier version.")
              }
              .controlSize(.small)
              .disabled(!sounds.isIdle)
            }
          }
          .padding(.horizontal, 8)
          .padding(.vertical, 4)
          .background(
            RoundedRectangle(cornerRadius: 6).fill(
              isCurrent ? AnyShapeStyle(Color.accentColor.opacity(0.12)) : AnyShapeStyle(.clear)))
        }
      }
    }
  }

  // MARK: - A composition

  @ViewBuilder
  private func jobPreview(_ job: AlertSoundLibraryModel.Job) -> some View {
    stage {
      if job.isUnderWay {
        VStack(spacing: 10) {
          ProgressView()
          AlertSoundProgressText(sounds: sounds, job: job)
            .font(.callout)
            .foregroundStyle(.secondary)
        }
      } else {
        Image(systemName: "exclamationmark.triangle")
          .font(.largeTitle)
          .foregroundStyle(.red)
      }
    }
    Text(verbatim: AlertSoundJobRow.title(of: job))
      .font(.title3.weight(.semibold))
      .lineLimit(2)
    if case .failed(let error, _) = job.phase {
      problemLabel(Text(AlertSoundPresentation.message(for: .generation(error))))
      HStack {
        Button {
          sounds.retry(job.id)
        } label: {
          Text("Try Again", bundle: .module)
        }
        .buttonStyle(.borderedProminent)
        .disabled(!sounds.isIdle)
        Button {
          sounds.dismiss(job.id)
        } label: {
          Text("Remove", bundle: .module)
        }
      }
    } else {
      Button {
        sounds.cancel()
      } label: {
        Text("Cancel", bundle: .module)
      }
    }
  }

  // MARK: - Parts

  private func stage<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
    ZStack {
      RoundedRectangle(cornerRadius: 12).fill(.quaternary)
      content()
    }
    .frame(maxWidth: .infinity)
    .frame(minHeight: 150)
  }

  private func problemLabel(_ text: Text) -> some View {
    Label {
      text.fixedSize(horizontal: false, vertical: true)
    } icon: {
      Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
    }
    .font(.callout)
    .accessibilityIdentifier("alert-sound-problem")
  }

  /// The problems said in an alert by the page, rather than here.
  private func isAlert(_ problem: AlertSoundLibraryModel.Problem) -> Bool {
    switch problem {
    case .importing, .limitReached: true
    default: false
    }
  }
}

/// A notification, as macOS shows one, for the sound to accompany. Decorative.
struct DemoNotification: View {
  var body: some View {
    HStack(spacing: 10) {
      Image(nsImage: NSApp?.applicationIconImage ?? NSImage())
        .resizable()
        .frame(width: 28, height: 28)
      VStack(alignment: .leading, spacing: 1) {
        Text(verbatim: "Refacto API — Claude Code")
          .font(.caption.weight(.semibold))
        Text("Permission requested: shell command", bundle: .module)
          .font(.caption)
          .foregroundStyle(.secondary)
      }
      Spacer(minLength: 0)
    }
    .lineLimit(1)
    .padding(.horizontal, 10)
    .padding(.vertical, 8)
    .background(
      RoundedRectangle(cornerRadius: 12)
        .fill(.background)
        .shadow(color: .black.opacity(0.12), radius: 6, y: 2)
    )
    .accessibilityHidden(true)
  }
}

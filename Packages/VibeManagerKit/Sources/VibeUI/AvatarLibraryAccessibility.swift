import Foundation
import SwiftUI
import VibeApplication

/// What VoiceOver hears on the page of the avatars (#154), apart from the views: each row one
/// element, its name and where it comes from, then its state; its actions; the card's state.
///
/// Every sentence goes through `resolve`, the application's language by default: the tests hand
/// it the French table.
extension AvatarLibraryPresentation {
  typealias Resolve = (LocalizedStringResource) -> String

  /// A label and a value, as VoiceOver reads them: the value after the label.
  struct Spoken: Equatable {
    var label: String
    var value: String
  }

  /// What an action of a row does, for VoiceOver.
  enum RowAction: Hashable, CaseIterable {
    case use, rename, duplicate, export, exportWithoutDescription, delete, discard, cancel
  }

  /// What an action of a generation's row does, for VoiceOver.
  enum JobAction: Hashable, CaseIterable {
    case cancel, retry, saveAgain, remove
  }

  static var resolved: Resolve { { String(localized: $0) } }

  // MARK: - Rows

  /// A row of an avatar: "Renard roux, dessiné par Codex le 26 septembre 2026", then its states —
  /// "en usage", "à valider", "génération en cours, 42 secondes", "illisible", "incomplet"…
  @MainActor
  static func spoken(
    _ entry: AvatarLibraryEntry, avatars: AvatarLibraryModel, now: Date, locale: Locale,
    resolve: Resolve = resolved
  ) -> Spoken {
    let name =
      entry.id == .default
      ? resolve(AvatarLibraryRules.defaultAvatarTitle)
      : DisplaySafeText.visible(AvatarLibraryModel.name(of: entry))
    var label = [name]
    if let origin = spokenOrigin(of: entry, avatars: avatars, locale: locale, resolve: resolve) {
      label.append(origin)
    }
    var states: [String] = []
    if entry.id == avatars.inUse { states.append(resolve(AvatarBadge.Kind.inUse.title)) }
    if entry.isDraft { states.append(resolve(AvatarBadge.Kind.toCheck.title)) }
    switch entry.problem {
    case .unreadable:
      states.append(resolve(AvatarBadge.Kind.unreadable.title))
    case .incomplete(let missing):
      states.append(resolve(AvatarBadge.Kind.incomplete.title))
      states.append(resolve(missingCount(missing.count)))
    case nil:
      break
    }
    if let work = avatars.work, work.avatar == entry.id {
      states.append(spokenProgress(of: work, now: now, locale: locale, resolve: resolve))
    }
    return Spoken(
      label: label.joined(separator: ", "), value: states.joined(separator: ", "))
  }

  /// A generation that is not an avatar yet: its description's first line, then how it goes.
  static func spoken(
    _ job: AvatarLibraryModel.Job, now: Date, locale: Locale, resolve: Resolve = resolved
  ) -> Spoken {
    let label =
      firstLine(of: job.description).map(DisplaySafeText.visible)
      ?? resolve(newAvatarTitle)
    let value: String
    switch job.phase {
    case .running, .writing:
      value = spokenProgress(of: job, now: now, locale: locale, resolve: resolve)
    case .failed(_, let at):
      let when = spokenRelative(locale).localizedString(for: at, relativeTo: now)
      value = resolve(
        LocalizedStringResource(
          "Failed, \(when)", bundle: .module,
          comment: "Read by VoiceOver: a generation that failed, and when (“2 minutes ago”)."))
    case .unsaved:
      value = [
        resolve(AvatarBadge.Kind.failed.title),
        resolve(LocalizedStringResource("Not written to disk yet", bundle: .module)),
      ].joined(separator: ", ")
    }
    return Spoken(label: label, value: value)
  }

  /// Where an avatar comes from, as a phrase: "drawn by Codex on September 26, 2026".
  @MainActor
  private static func spokenOrigin(
    of entry: AvatarLibraryEntry, avatars: AvatarLibraryModel, locale: Locale, resolve: Resolve
  ) -> String? {
    if entry.id == .default {
      return resolve(
        LocalizedStringResource(
          "shipped with the application", bundle: .module,
          comment: "Read by VoiceOver after the default avatar's name."))
    }
    guard let manifest = entry.manifest else { return nil }
    let date = (manifest.createdAt ?? entry.addedAt).formatted(
      .dateTime.day().month(.wide).year().locale(locale))
    switch manifest.source {
    case .generated:
      let agent = agentName(manifest.provider ?? "", avatars: avatars)
      return resolve(
        LocalizedStringResource(
          "drawn by \(agent) on \(date)", bundle: .module,
          comment: "Read by VoiceOver after an avatar's name: the agent that drew it, and when."))
    case .imported, .bundled:
      return resolve(
        LocalizedStringResource(
          "imported on \(date)", bundle: .module,
          comment: "Read by VoiceOver after an avatar's name: made from an archive, and when."))
    }
  }

  /// "Generation under way, less than a minute", then "…, 1 minute", "…, 2 minutes": whole
  /// minutes, so that VoiceOver does not read the row again every second — the row itself shows
  /// the seconds. "Saving…" once it can no longer be cancelled.
  private static func spokenProgress(
    of job: AvatarLibraryModel.Job, now: Date, locale: Locale, resolve: Resolve
  ) -> String {
    guard job.phase == .running else {
      return resolve(
        LocalizedStringResource(
          "Saving…", bundle: .module, comment: "A generated avatar being written to disk."))
    }
    let elapsed = spokenElapsed(
      now.timeIntervalSince(job.startedAt), locale: locale, resolve: resolve)
    return resolve(
      LocalizedStringResource(
        "Generation under way, \(elapsed)", bundle: .module,
        comment: "Read by VoiceOver: an avatar being drawn, and for how long (“2 minutes”)."))
  }

  /// How long a generation has taken, in whole minutes: "less than a minute", "1 minute"…
  static func spokenElapsed(_ interval: TimeInterval, locale: Locale, resolve: Resolve) -> String {
    let minutes = Int(max(interval, 0) / 60)
    guard minutes > 0 else {
      return resolve(
        LocalizedStringResource(
          "less than a minute", bundle: .module,
          comment: "Read by VoiceOver: how long an avatar has been drawn for, under a minute."))
    }
    return Duration.seconds(minutes * 60)
      .formatted(.units(allowed: [.hours, .minutes], width: .wide).locale(locale))
  }

  /// When what VoiceOver reads of a row may change: each minute from `anchor`, the start of a
  /// generation or the moment it failed.
  static func spokenSchedule(from anchor: Date?) -> PeriodicTimelineSchedule {
    .periodic(from: anchor ?? .distantPast, by: 60)
  }

  /// "2 minutes ago", counted from `now`.
  static func spokenRelative(_ locale: Locale) -> RelativeDateTimeFormatter {
    let formatter = RelativeDateTimeFormatter()
    formatter.locale = locale
    formatter.unitsStyle = .full
    formatter.dateTimeStyle = .named
    return formatter
  }

  static func missingCount(_ count: Int) -> LocalizedStringResource {
    LocalizedStringResource("\(count) expressions missing", bundle: .module)
  }

  // MARK: - Actions

  /// The actions VoiceOver offers on the row of an avatar: those of its menu that can be done
  /// now, and Cancel while one of its expressions is being drawn again.
  @MainActor
  static func rowActions(for entry: AvatarLibraryEntry, avatars: AvatarLibraryModel)
    -> [RowAction]
  {
    let actions = self.actions(
      for: entry, inUse: avatars.inUse, canCreate: avatars.canCreate,
      canRename: avatars.canRename(entry.id))
    var offered: [RowAction] = []
    if actions.enabled(.use) { offered.append(.use) }
    if actions.enabled(.rename) { offered.append(.rename) }
    if actions.enabled(.duplicate) { offered.append(.duplicate) }
    if actions.enabled(.export) { offered += [.export, .exportWithoutDescription] }
    if actions.enabled(.delete) { offered.append(entry.isDraft ? .discard : .delete) }
    if let work = avatars.work, work.avatar == entry.id, work.phase == .running {
      offered.append(.cancel)
    }
    return offered
  }

  /// The actions VoiceOver offers on the row of a generation: Cancel while it runs; Try Again —
  /// when something new can be started — or Save Again, and Remove, once it failed.
  @MainActor
  static func jobActions(for job: AvatarLibraryModel.Job, avatars: AvatarLibraryModel)
    -> [JobAction]
  {
    switch job.phase {
    case .running: return [.cancel]
    case .writing: return []
    case .failed: return avatars.canStartCreation ? [.retry, .remove] : [.remove]
    case .unsaved: return avatars.work == nil ? [.saveAgain, .remove] : [.remove]
    }
  }

  static func title(of action: RowAction) -> LocalizedStringResource {
    switch action {
    case .use: LocalizedStringResource("Use This Avatar", bundle: .module)
    case .rename: LocalizedStringResource("Rename…", bundle: .module)
    case .duplicate: LocalizedStringResource("Duplicate", bundle: .module)
    case .export: LocalizedStringResource("Export…", bundle: .module)
    case .exportWithoutDescription:
      LocalizedStringResource("Export Without the Description…", bundle: .module)
    case .delete: LocalizedStringResource("Delete…", bundle: .module)
    case .discard: LocalizedStringResource("Discard…", bundle: .module)
    case .cancel: LocalizedStringResource("Cancel", bundle: .module)
    }
  }

  static func title(of action: JobAction) -> LocalizedStringResource {
    switch action {
    case .cancel: LocalizedStringResource("Cancel", bundle: .module)
    case .retry: LocalizedStringResource("Try Again", bundle: .module)
    case .saveAgain:
      LocalizedStringResource(
        "Save Again", bundle: .module, comment: "Writes a generated avatar again.")
    case .remove: LocalizedStringResource("Remove", bundle: .module)
    }
  }

  // MARK: - The card and the expressions

  /// The card that makes a new avatar: a button whose value says whether it is unfolded — and,
  /// greyed out, why.
  static func spokenCard(
    isOpen: Bool, reason: LocalizedStringResource?, resolve: Resolve = resolved
  ) -> Spoken {
    let state =
      isOpen
      ? resolve(LocalizedStringResource("Unfolded", bundle: .module))
      : resolve(LocalizedStringResource("Folded", bundle: .module))
    return Spoken(
      label: resolve(LocalizedStringResource("Create a New Avatar", bundle: .module)),
      value: ([state] + (reason.map { [resolve($0)] } ?? [])).joined(separator: ", "))
  }

  /// An expression of the preview: its name, and "missing" when the avatar lacks it.
  static func spokenExpression(
    _ expression: AvatarExpression, isMissing: Bool, resolve: Resolve = resolved
  ) -> String {
    let name = resolve(AvatarPresentation.name(of: expression))
    guard isMissing else { return name }
    return resolve(
      LocalizedStringResource(
        "\(name), missing", bundle: .module,
        comment: "Read by VoiceOver: an expression the avatar lacks, after its name."))
  }

  // MARK: - Names

  static var newAvatarTitle: LocalizedStringResource {
    LocalizedStringResource("New Avatar", bundle: .module)
  }

  /// The first line of a description that says something.
  static func firstLine(of description: String) -> String? {
    description.split(whereSeparator: \.isNewline)
      .map { $0.trimmingCharacters(in: .whitespaces) }
      .first { !$0.isEmpty }
  }
}

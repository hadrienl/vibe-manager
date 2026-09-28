import Foundation
import Testing
import VibeApplication
import VibeLocalizationTesting

@testable import VibeUI

/// The words of Settings › Requests and of its page of avatars (#154), in French: each one
/// translated, with French typography — a no-break space before “:”, “;”, “?”, “!” and inside
/// « ».
@MainActor
@Suite("The avatars' text, in English and in French")
struct AvatarLocalizationTests {
  /// Every problem the page can show or announce.
  private static var problems: [AvatarLibraryModel.Problem] {
    let archive: [AvatarProblem] = [
      .unreadableImage, .imageTooLarge,
      .wrongGrid(expectedColumns: 5, expectedRows: 2, width: 1024, height: 1024), .cellTooSmall,
      .emptyCell(.pleased), .cutCell(.pleased), .inconsistentSize(.pleased),
      .backgroundNotRemoved(.pleased), .archiveUnreadable, .archiveTooLarge,
      .archiveUnsafeEntry("../x"), .archiveEncrypted, .archiveFromNewerVersion,
      .archiveHasNoImage, .imageNotSquare(.pleased), .imageTooSmall(.pleased),
      .duplicateExpression(.pleased), .imagesOfDifferentSizes(.pleased),
    ]
    let generation: [AvatarGenerationError] = [
      .unavailable(.notCapable), .unavailable(.missing), .unavailable(.outdated),
      .unavailable(.signedOut), .timedOut, .noImage, .failed("x"), .rejected(.cellTooSmall),
    ]
    return archive.map { .archive($0) } + generation.map { .generation($0) } + [
      .storedAvatar(missing: [.worried]), .storedAvatar(missing: []), .limitReached, .writing,
      .importing, .keeping, .using, .renaming, .duplicating, .deleting, .completing, .exporting,
    ]
  }

  /// Every label of the page that is not a sentence built from the user's words.
  private static var labels: [LocalizedStringResource] {
    let badges: [AvatarBadge.Kind] = [
      .inUse, .toCheck, .running, .failed, .unreadable, .incomplete,
    ]
    return badges.map(\.title)
      + AvatarLibraryPresentation.RowAction.allCases.map(AvatarLibraryPresentation.title(of:))
      + AvatarLibraryPresentation.JobAction.allCases.map(AvatarLibraryPresentation.title(of:))
      + AvatarExpression.allCases.map(AvatarPresentation.name(of:))
      + RequestsPane.allCases.map(\.title)
      + [
        AvatarLibraryPresentation.newAvatarTitle, AvatarLibraryPresentation.missingCount(2),
        AvatarLibraryRules.defaultAvatarTitle,
      ]
  }

  @Test("Every problem is said in French, with French typography")
  func problemsInFrench() {
    for problem in Self.problems {
      let resource = AvatarPresentation.message(for: problem)
      Self.expectFrench(resource, "\(problem)")
    }
  }

  @Test("Every label of the page is in French")
  func labelsInFrench() {
    for label in Self.labels {
      Self.expectFrench(label, "\(label.key)")
    }
  }

  @Test("What VoiceOver hears is French, and typographically so")
  func spokenInFrench() {
    let french: AvatarLibraryPresentation.Resolve = { Localization.string($0, in: "fr") }
    let card = AvatarLibraryPresentation.spokenCard(
      isOpen: false, reason: AvatarPresentation.message(for: .limitReached), resolve: french)
    #expect(card.label == "Créer un nouvel avatar")
    #expect(
      card.value == "Replié, 20 avatars au plus\u{00A0}: supprimez-en un pour en créer un autre.")
    #expect(
      AvatarLibraryPresentation.spokenExpression(.mouthRound, isMissing: true, resolve: french)
        == "Bouche en «\u{00A0}O\u{00A0}», manquante")
  }

  @Test("The summary counts avatars in French, one and many")
  func summary() {
    let fr = Locale(identifier: "fr")
    #expect(
      Localization.string(
        AvatarLibraryPresentation.summary(count: 1, byteCount: 0, locale: fr), in: "fr"
      ).hasPrefix("1 avatar · "))
    #expect(
      Localization.string(
        AvatarLibraryPresentation.summary(count: 20, byteCount: 0, locale: fr), in: "fr"
      ).hasPrefix("20 avatars · "))
  }

  /// Translated — not the English text — and with its no-break spaces.
  private static func expectFrench(
    _ resource: LocalizedStringResource, _ what: String,
    sourceLocation: SourceLocation = #_sourceLocation
  ) {
    let english = Localization.string(resource, in: "en")
    let french = Localization.string(resource, in: "fr")
    // A few words are the same in both languages.
    let alike: Set<String> = ["Avatars", "Expressions", "Incomplete"]
    #expect(
      french != english || alike.contains(english), "Not translated: \(what) → \(french)",
      sourceLocation: sourceLocation)
    let breakable = french.range(of: #" [:;?!»]|« "#, options: .regularExpression)
    #expect(
      breakable == nil, "A breakable space in the French of \(what): \(french)",
      sourceLocation: sourceLocation)
  }
}

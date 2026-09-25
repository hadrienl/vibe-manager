import Foundation
import Testing
import VibeLocalizationTesting
import VibePersistence

@Suite("The store's messages, in English and in French")
struct LocalizationTests {
  @Test("A damaged store says so in both languages")
  func storeErrors() {
    let error = SessionStoreError.corruptedStore(backupAvailable: true)
    #expect(error.errorDescription == "The session store is damaged, but a backup can be restored.")
    #expect(
      Localization.string(
        "The session store is damaged, but a backup can be restored.", module: "VibePersistence",
        in: "fr")
        == "Le fichier des sessions est endommagé, mais une sauvegarde peut être restaurée.")
  }
}

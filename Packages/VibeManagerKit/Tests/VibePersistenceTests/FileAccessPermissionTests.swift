import Foundation
import Testing
import VibeApplication
import VibePersistence

@Suite("Reading the file access the system granted")
struct TCCFullDiskAccessProbeTests {
  @Test("A witness it can open means the access is there")
  func readableWitnessMeansGranted() async throws {
    let witness = FileManager.default.temporaryDirectory
      .appendingPathComponent("witness-\(UUID().uuidString).db")
    try Data("x".utf8).write(to: witness)
    defer { try? FileManager.default.removeItem(at: witness) }

    let probe = TCCFullDiskAccessProbe(witnessPath: witness.path)

    #expect(await probe.status() == .granted)
  }

  @Test("A witness it cannot open means the access is missing")
  func hiddenWitnessMeansNotGranted() async {
    // This is exactly what the real refusal looks like from inside the process: without Full
    // Disk Access the path is hidden rather than denied, and nothing is shown to the user.
    let probe = TCCFullDiskAccessProbe(
      witnessPath: "/nonexistent-\(UUID().uuidString)/TCC.db"
    )

    #expect(await probe.status() == .notGranted)
  }
}

@Suite("Remembering the permission steps already answered")
struct UserDefaultsPermissionPreferencesTests {
  @Test("Nothing has been answered until something is")
  func startsUnanswered() async {
    let preferences = makePreferences()

    #expect(await preferences.isFullDiskAccessStepDismissed() == false)
  }

  @Test("An answer survives, so the step is not asked twice")
  func answerIsRemembered() async {
    let preferences = makePreferences()

    await preferences.dismissFullDiskAccessStep()

    #expect(await preferences.isFullDiskAccessStepDismissed())
  }

  private func makePreferences() -> UserDefaultsPermissionPreferences {
    let suiteName = "com.hadrienl.VibeManager.tests.\(UUID().uuidString)"
    UserDefaults(suiteName: suiteName)?.removePersistentDomain(forName: suiteName)
    return UserDefaultsPermissionPreferences(suiteName: suiteName)
  }
}

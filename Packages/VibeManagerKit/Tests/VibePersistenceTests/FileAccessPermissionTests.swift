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
    let (preferences, _) = makePreferences()

    #expect(await preferences.fullDiskAccessStepAnswer() == nil)
  }

  @Test("An answer survives, with the identity that gave it")
  func answerIsRemembered() async {
    let (preferences, _) = makePreferences()
    let identity = CodeIdentityFingerprint(
      identifier: "eu.hadrien.VibeManager", team: "QMJKZ67Z3H", designatedRequirement: "anchor")

    await preferences.recordFullDiskAccessStepAnswer(by: identity)

    #expect(await preferences.fullDiskAccessStepAnswer() == identity)
  }

  @Test("The boolean of the first version is no answer: the step comes back once")
  func firstVersionIsNotAnAnswer() async throws {
    // It survived the change of bundle identifier that made TCC forget the access (#76), and kept
    // the step away from the very users that change stranded.
    let (preferences, suiteName) = makePreferences()
    let defaults = try #require(UserDefaults(suiteName: suiteName))
    defaults.set(true, forKey: "permissions.fullDiskAccess.stepDismissed.v1")

    #expect(await preferences.fullDiskAccessStepAnswer() == nil)
    #expect(defaults.bool(forKey: "permissions.fullDiskAccess.stepDismissed.v1"))
  }

  private func makePreferences() -> (UserDefaultsPermissionPreferences, String) {
    let suiteName = "com.hadrienl.VibeManager.tests.\(UUID().uuidString)"
    UserDefaults(suiteName: suiteName)?.removePersistentDomain(forName: suiteName)
    return (UserDefaultsPermissionPreferences(suiteName: suiteName), suiteName)
  }
}

@Suite("Reading the code identity TCC holds grants against")
struct SecCodeIdentityReaderTests {
  @Test("The test binary, signed ad hoc or not at all, reads as one stable identity")
  func testBinaryIsStable() {
    let reader = SecCodeIdentityReader()

    let first = reader.current()

    #expect(first == reader.current())
    #expect(first.rawValue.hasPrefix("adhoc|") || first == .unidentified)
  }
}

@Suite("Suppressing the permission step for an automated run")
struct PermissionStepSuppressionTests {
  @Test("Only a value set from outside suppresses the step")
  func suppressionIsReadFromTheDefaults() async throws {
    let suiteName = "com.hadrienl.VibeManager.tests.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }
    #expect(
      await UserDefaultsPermissionPreferences(suiteName: suiteName)
        .isFullDiskAccessStepSuppressed() == false)

    defaults.set(true, forKey: "permissions.fullDiskAccess.stepSuppressed")
    defaults.synchronize()

    #expect(
      await UserDefaultsPermissionPreferences(suiteName: suiteName)
        .isFullDiskAccessStepSuppressed())
  }
}

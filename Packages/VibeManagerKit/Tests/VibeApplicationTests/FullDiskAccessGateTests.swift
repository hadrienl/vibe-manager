import Testing
import VibeApplication

@Suite("Asking for file access once")
struct FullDiskAccessGateTests {
  @Test("With the access granted, there is nothing to ask")
  func grantedAsksNothing() async {
    let gate = FullDiskAccessGate(
      probe: StubProbe(status: .granted),
      preferences: SpyPreferences(dismissed: false)
    )

    #expect(await gate.status() == .granted)
    #expect(await gate.shouldPresentStep() == false)
  }

  @Test("Without it, and never asked, the step is presented")
  func notGrantedAsksOnce() async {
    let gate = FullDiskAccessGate(
      probe: StubProbe(status: .notGranted),
      preferences: SpyPreferences(dismissed: false)
    )

    #expect(await gate.shouldPresentStep())
  }

  @Test("A refusal is an answer: the step does not come back at the next launch")
  func refusalIsNotAskedAgain() async {
    let gate = FullDiskAccessGate(
      probe: StubProbe(status: .notGranted),
      preferences: SpyPreferences(dismissed: true)
    )

    #expect(await gate.shouldPresentStep() == false)
  }

  @Test("Answering the step records it, once")
  func dismissingIsRecorded() async {
    let preferences = SpyPreferences(dismissed: false)
    let gate = FullDiskAccessGate(probe: StubProbe(status: .notGranted), preferences: preferences)

    #expect(await gate.shouldPresentStep())
    await gate.dismissStep()

    #expect(await preferences.dismissals == 1)
    #expect(await gate.shouldPresentStep() == false)
  }

  @Test("The system is asked once per launch, not once per question")
  func statusIsProbedOnce() async {
    // TCC freezes a process's permissions when it starts, so a second probe could only repeat
    // the first answer — and it is the same fact that makes the step talk about relaunching.
    let probe = StubProbe(status: .notGranted)
    let gate = FullDiskAccessGate(probe: probe, preferences: SpyPreferences(dismissed: false))

    _ = await gate.status()
    _ = await gate.shouldPresentStep()
    _ = await gate.status()

    #expect(await probe.probes == 1)
  }
}

private actor StubProbe: FullDiskAccessProbe {
  private let value: FullDiskAccessStatus
  private(set) var probes = 0

  init(status: FullDiskAccessStatus) {
    value = status
  }

  func status() async -> FullDiskAccessStatus {
    probes += 1
    return value
  }
}

private actor SpyPreferences: PermissionPreferences {
  private var dismissed: Bool
  private(set) var dismissals = 0

  init(dismissed: Bool) {
    self.dismissed = dismissed
  }

  func isFullDiskAccessStepDismissed() -> Bool { dismissed }

  func dismissFullDiskAccessStep() {
    dismissals += 1
    dismissed = true
  }
}

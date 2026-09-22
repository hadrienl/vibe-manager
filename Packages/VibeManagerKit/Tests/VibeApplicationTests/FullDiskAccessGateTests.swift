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

  @Test("A screen the user opened themselves may ask the system again")
  func refreshedStatusAsksAgain() async {
    // Someone opening the settings window has usually just come back from System Settings, and
    // a row answering from a decision taken at launch would be a row that lies.
    let probe = StubProbe(status: .notGranted)
    let gate = FullDiskAccessGate(probe: probe, preferences: SpyPreferences(dismissed: false))

    _ = await gate.status()
    await probe.grant()
    #expect(await gate.refreshedStatus() == .granted)
    #expect(await gate.status() == .granted)
    #expect(await probe.probes == 2)
  }

  @Test("The step is offered once per launch, whoever asks")
  func stepIsOfferedOncePerLaunch() async {
    // The answer is written asynchronously, and a second caller reading the preferences in that
    // window would otherwise be told to present a step the user is already looking at.
    let gate = FullDiskAccessGate(
      probe: StubProbe(status: .notGranted),
      preferences: SpyPreferences(dismissed: false)
    )

    #expect(await gate.shouldPresentStep())
    #expect(await gate.shouldPresentStep() == false)
  }

  @Test("Two callers asking at the same time still get one step")
  func concurrentCallersAreOfferedOneStep() async {
    // Both questions the gate asks leave the actor, so "at the same time" is not hypothetical:
    // a second caller can run all the way through while the first is waiting on the probe.
    let gate = FullDiskAccessGate(
      probe: SlowProbe(status: .notGranted),
      preferences: SlowPreferences()
    )

    async let first = gate.shouldPresentStep()
    async let second = gate.shouldPresentStep()
    let answers = await [first, second]

    #expect(answers.filter { $0 }.count == 1)
  }

  @Test("A step withheld because access was granted is not owed forever")
  func aStepNotPresentedIsNotSpent() async {
    // Nothing was shown, so nothing was answered: if the status reads differently later in the
    // same launch, the step is still the gate's to offer.
    let probe = RevokingProbe()
    let gate = FullDiskAccessGate(probe: probe, preferences: SpyPreferences(dismissed: false))

    #expect(await gate.shouldPresentStep() == false)
    _ = await gate.refreshedStatus()

    #expect(await gate.shouldPresentStep())
  }
}

/// Suspends before answering, so that a second caller really does run in the gap.
private actor SlowProbe: FullDiskAccessProbe {
  private let value: FullDiskAccessStatus

  init(status: FullDiskAccessStatus) {
    value = status
  }

  func status() async -> FullDiskAccessStatus {
    await Task.yield()
    return value
  }
}

private actor SlowPreferences: PermissionPreferences {
  private var dismissed = false

  func isFullDiskAccessStepDismissed() async -> Bool {
    await Task.yield()
    return dismissed
  }

  func dismissFullDiskAccessStep() { dismissed = true }
}

/// Granted when first asked, and not the second time — the shape of an access taken away in
/// System Settings while the application is running.
private actor RevokingProbe: FullDiskAccessProbe {
  private var probes = 0

  func status() async -> FullDiskAccessStatus {
    probes += 1
    return probes == 1 ? .granted : .notGranted
  }
}

private actor StubProbe: FullDiskAccessProbe {
  private var value: FullDiskAccessStatus
  private(set) var probes = 0

  init(status: FullDiskAccessStatus) {
    value = status
  }

  func grant() { value = .granted }

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

import AppKit
import Foundation
import Testing
import VibeApplication
import VibeDomain

@testable import VibeUI

/// The agent's menu of the status bar (#575): what it opens, and the history it reads.
@MainActor
@Suite("The agent of a session in its status bar", .timeLimit(.minutes(1)))
struct SessionAgentMenuTests {
  private static let stub = WorkspaceProvider(
    catalog: [
      AgentModel(id: "fast", displayName: "Fast"), AgentModel(id: "deep", displayName: "Deep"),
    ])
  private static let other = WorkspaceProvider(
    id: "other", name: "Other Agent", catalog: [AgentModel(id: "o1", displayName: "O1")])
  private static let names = ["stub": "Stub Agent", "other": "Other Agent"]

  private func session(history: [AgentChange] = []) -> WorkSession {
    WorkSession(
      name: "Audit deps",
      initialPrompt: "Audit the dependencies.",
      agent: SessionAgentConfiguration(providerID: "stub", modelID: "fast"),
      status: .closed,
      createdAt: Date(timeIntervalSince1970: 1_699_000_000),
      updatedAt: Date(timeIntervalSince1970: 1_700_000_000),
      closedAt: Date(timeIntervalSince1970: 1_700_000_000),
      startedAt: Date(timeIntervalSince1970: 1_699_000_100),
      agentHistory: history
    )
  }

  private func workspace(_ session: WorkSession) async -> (AppModel, WorkspaceRepository) {
    let repository = WorkspaceRepository(sessions: [session])
    let registry = WorkspaceRegistry(providers: [Self.stub, Self.other])
    let launcher = SessionLauncher(
      supervisor: WorkspaceSupervisor(), repository: repository, agents: registry,
      viewportTimeout: .zero)
    let model = AppModel(repository: repository, agents: registry, launcher: launcher)
    await model.reload()
    return (model, repository)
  }

  @Test("A model of the menu opens the sheet set on it, the agent's models listed")
  func choiceIsPreselected() async throws {
    let subject = session()
    let (model, _) = await workspace(subject)
    let choices = await AgentSwitchChoices.read(
      from: WorkspaceRegistry(providers: [Self.stub, Self.other]))
    let other = try #require(choices.agent("other"))
    let choice = try #require(choices.choices(for: other, current: subject.agent).first)

    SessionAgentMenu.open(choice, of: subject.id, in: model)

    let sheet = try #require(model.pendingSwitch)
    #expect(sheet.target == AgentTarget(providerID: "other", modelID: "o1"))
    await sheet.load()
    #expect(sheet.models.map(\.id) == ["o1"])
    #expect(sheet.changesSomething)
  }

  @Test("Another agent's default model opens the sheet on that default, not on the current model")
  func defaultModelIsKept() async throws {
    let subject = session()
    let (model, _) = await workspace(subject)

    SessionAgentMenu.open(
      AgentSwitchChoices.Choice(
        target: AgentTarget(providerID: "other"), modelName: nil, isCurrent: false),
      of: subject.id, in: model)

    let sheet = try #require(model.pendingSwitch)
    #expect(sheet.target == AgentTarget(providerID: "other"))
  }

  @Test("Other Settings… opens the sheet on the session's own agent")
  func otherSettingsPreselectsNothing() async throws {
    let subject = session()
    let (model, _) = await workspace(subject)

    SessionAgentMenu.open(nil, of: subject.id, in: model)

    let sheet = try #require(model.pendingSwitch)
    #expect(sheet.target == AgentTarget(providerID: "stub", modelID: "fast"))
    #expect(!sheet.changesSomething)
  }

  @Test("Nothing opens when the session cannot be switched")
  func nothingWhenNotSwitchable() async throws {
    let subject = session()
    let (model, repository) = await workspace(subject)
    await repository.archive(subject.id)
    await model.reload()

    SessionAgentMenu.open(
      AgentSwitchChoices.Choice(
        target: AgentTarget(providerID: "other", modelID: "o1"), modelName: "O1", isCurrent: false),
      of: subject.id, in: model)

    #expect(model.pendingSwitch == nil)
  }

  @Test("The history reads newest first, failures marked, and ends with the start")
  func historyNewestFirst() {
    let first = AgentChange(
      date: Date(timeIntervalSince1970: 1_699_500_000),
      previous: SessionAgentConfiguration(providerID: "other", modelID: "o1"),
      next: SessionAgentConfiguration(providerID: "stub", modelID: "fast"),
      handover: .summary(byteCount: 1_200, isTruncated: false, wasEdited: false))
    let failed = AgentChange(
      date: Date(timeIntervalSince1970: 1_699_600_000),
      previous: SessionAgentConfiguration(providerID: "stub", modelID: "fast"),
      next: SessionAgentConfiguration(providerID: "stub", modelID: "deep"),
      handover: .resumedConversation, outcome: .failed(reason: "Unknown model."))

    let history = AgentHistoryPresentation(
      session: session(history: [first, failed]), names: AgentLabels(names: Self.names))

    #expect(history.hasChanges)
    #expect(history.entries.map(\.id) == [.change(failed.id), .change(first.id), .start])
    #expect(history.entries.map(\.failed) == [true, false, false])
    // The agent and the model, whole, on both sides of every switch.
    #expect(history.entries[0].title.contains("Stub Agent · deep"))
    #expect(history.entries[0].detail.hasSuffix(" · Unknown model."))
    #expect(history.entries[1].title == "Other Agent · o1 → Stub Agent · fast")
    #expect(history.entries[1].detail.hasSuffix(AgentHistoryPresentation.handover(first.handover)))
    #expect(history.entries[1].spoken.contains("Other Agent · o1"))
    // The first agent is the one the first real switch left.
    #expect(history.entries[2].title.contains("Other Agent · o1"))
  }

  @Test("Models are named as their catalogue names them, else by their identifier")
  func catalogueNames() {
    let labels = AgentLabels(names: Self.names, models: ["other": ["o1": "O1 Pro"]])
    #expect(
      labels.label(SessionAgentConfiguration(providerID: "other", modelID: "o1"))
        == "Other Agent · O1 Pro")
    #expect(
      labels.label(SessionAgentConfiguration(providerID: "stub", modelID: "fast"))
        == "Stub Agent · fast")
    #expect(labels.label(SessionAgentConfiguration(providerID: "stub")) == "Stub Agent")
  }

  @Test("A session that never switched has no history to show")
  func noHistory() {
    let history = AgentHistoryPresentation(
      session: session(), names: AgentLabels(names: Self.names))
    #expect(!history.hasChanges)
    #expect(history.entries.map(\.id) == [.start])
  }

  /// A session that switched twice, one of them failed, its menu as AppKit gets it.
  private func menu(
    of subject: WorkSession, in model: AppModel, state: String = "Ready to resume."
  ) async -> AgentMenu.Menu {
    let choices = await AgentSwitchChoices.read(
      from: WorkspaceRegistry(providers: [Self.stub, Self.other]))
    let names = AgentLabels(names: Self.names, models: choices.modelNames)
    let content = AgentMenuContent(
      session: subject, names: names, choices: choices, state: state,
      canSwitch: model.canSwitchAgent(subject))
    let id = subject.id
    return AgentMenu.make(content) { target in
      model.beginAgentSwitch(id, preselected: target)
    }
  }

  private var switched: WorkSession {
    session(history: [
      AgentChange(
        date: Date(timeIntervalSince1970: 1_699_500_000),
        previous: SessionAgentConfiguration(providerID: "other", modelID: "o1"),
        next: SessionAgentConfiguration(providerID: "stub", modelID: "fast"),
        handover: .resumedConversation),
      AgentChange(
        date: Date(timeIntervalSince1970: 1_699_600_000),
        previous: SessionAgentConfiguration(providerID: "stub", modelID: "fast"),
        next: SessionAgentConfiguration(providerID: "other", modelID: "o1"),
        handover: .resumedConversation, outcome: .failed(reason: "Unknown model.")),
    ])
  }

  @Test("The first line: the agent's logo, its name and model in bold, its state under them")
  func currentAgentLine() async throws {
    let subject = switched
    let (model, _) = await workspace(subject)
    let menu = await menu(of: subject, in: model)

    let current = try #require(menu.items.first)
    #expect(current.title == "Stub Agent · Fast")
    let font = try #require(
      current.attributedTitle?.attribute(.font, at: 0, effectiveRange: nil) as? NSFont)
    #expect(NSFontManager.shared.traits(of: font).contains(.boldFontMask))
    // A subtitle ends without a stop.
    if #available(macOS 14.4, *) {
      #expect(current.subtitle == "Ready to resume")
    }
    #expect(current.image != nil)
    if #available(macOS 27, *) {
      #expect(current.preferredImageVisibility == .visible)
    }
    #expect(current.isEnabled)
  }

  @Test("The history reads in full: every line enabled, the failed one marked")
  func historyIsReadable() async throws {
    let subject = switched
    let (model, _) = await workspace(subject)
    let menu = await menu(of: subject, in: model)

    let history = try #require(menu.items.first?.submenu)
    #expect(history.items.count == 3)
    #expect(history.items.allSatisfy { $0.isEnabled })
    #expect(history.items[0].title == "⚠︎ → Other Agent · O1 failed")
    if #available(macOS 14.4, *) {
      #expect(history.items[0].subtitle?.hasSuffix(" · Unknown model.") == true)
    }
    #expect(history.items[1].title == "Other Agent · O1 → Stub Agent · Fast")
    #expect(history.items[2].title.contains("Other Agent · O1"))
  }

  @Test("Switch To: each agent under its logo, the model it runs checked, a model opens the sheet")
  func switchToSections() async throws {
    let subject = switched
    let (model, _) = await workspace(subject)
    let menu = await menu(of: subject, in: model)

    let switchTo = try #require(menu.items.last)
    #expect(switchTo.isEnabled)
    let models = try #require(switchTo.submenu)
    let headers = models.items.filter(\.isSectionHeader)
    #expect(headers.map(\.title) == ["Stub Agent", "Other Agent"])
    #expect(headers.allSatisfy { $0.image != nil })
    if #available(macOS 27, *) {
      #expect(headers.allSatisfy { $0.preferredImageVisibility == .visible })
    }
    let fast = try #require(models.items.first { $0.title == "Fast" })
    #expect(fast.state == .on && !fast.isEnabled)

    // The action is sent the way a click sends it, through the application.
    _ = NSApplication.shared
    let o1 = try #require(models.items.firstIndex { $0.title == "O1" })
    models.performActionForItem(at: o1)
    #expect(model.pendingSwitch?.target == AgentTarget(providerID: "other", modelID: "o1"))
  }
}

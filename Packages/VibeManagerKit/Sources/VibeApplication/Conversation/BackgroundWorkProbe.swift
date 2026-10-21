import Foundation
import VibeDomain

/// Whether a session's agent ended its turn with work still running in the background — a command
/// or a sub-agent it will hear from (#393). The user is not needed yet: the agent goes on by
/// itself once that work ends, and is said when it ends a turn with nothing left running.
///
/// Its transcript is read once, to its end, away from the main actor. Work started before the
/// agent's process — a process resumed since — never ends, and does not count; neither does
/// anything the transcript cannot tell, or a transcript that cannot be read: then the user is told.
public struct BackgroundWorkProbe: Sendable {
  private let agents: any AgentProviderResolving
  private let hint: @Sendable (SessionID) async -> AgentActivityEvent?

  public init(
    agents: any AgentProviderResolving,
    hint: @escaping @Sendable (SessionID) async -> AgentActivityEvent?
  ) {
    self.agents = agents
    self.hint = hint
  }

  /// - Parameter processStart: when the agent's process started.
  public func isWaiting(_ session: WorkSession, processStart: Date) async -> Bool {
    guard let conversation = session.conversationAgents.last,
      let reporter = await agents.provider(id: AgentProviderID(conversation.providerID))
        as? any AgentConversationReporting
    else { return false }
    let files = reporter.conversationFiles(
      for: conversation, in: session, hint: await hint(session.id))
    guard let file = files.last else { return false }
    return await Task.detached(priority: .utility) {
      guard let data = try? Data(contentsOf: file) else { return false }
      let decoder = reporter.conversationDecoder(for: file)
      for line in data.split(separator: UInt8(ascii: "\n")) {
        decoder.consume(Data(line))
      }
      return decoder.backgroundWork.contains { !SubagentRun.predates($0, process: processStart) }
    }.value
  }
}

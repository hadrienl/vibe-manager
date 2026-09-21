import Foundation

extension TerminalSpec {
  /// The terminal that runs one agent launch plan.
  ///
  /// The prompt is typed into the pseudo terminal only when the provider asked for that delivery.
  /// When the plan carries it as an argument, writing it again on the standard input would type
  /// it into the agent's composer — in a pseudo terminal, the standard input is the keyboard.
  public static func agent(
    plan: AgentLaunchPlan,
    size: TerminalSize = .default,
    scrollback: TerminalScrollbackLimits = .default
  ) -> TerminalSpec {
    let initialInput: String?
    switch plan.promptDelivery {
    case .standardInput(let text):
      initialInput = text
    case .argument, .none:
      initialInput = nil
    }

    return TerminalSpec(
      executableURL: plan.executableURL,
      arguments: plan.arguments,
      environment: plan.environment,
      workingDirectoryURL: plan.workingDirectoryURL,
      initialSize: size,
      initialInput: initialInput,
      scrollback: scrollback
    )
  }
}

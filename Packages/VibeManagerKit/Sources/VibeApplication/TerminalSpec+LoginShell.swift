import Foundation

extension TerminalSpec {
  // The user's own login shell, so their prompt, aliases and version managers behave as they do
  // in their terminal. `-l` is what makes the shell read its login files, which is where most
  // developer tooling puts its PATH.
  public static func loginShell(
    workingDirectoryURL: URL,
    size: TerminalSize = .default,
    scrollback: TerminalScrollbackLimits = .default
  ) -> TerminalSpec {
    let environment = TerminalEnvironment.make()
    let shellPath = environment["SHELL"].map { $0.isEmpty ? "/bin/zsh" : $0 } ?? "/bin/zsh"
    return TerminalSpec(
      executableURL: URL(fileURLWithPath: shellPath),
      arguments: ["-l"],
      environment: environment,
      workingDirectoryURL: workingDirectoryURL,
      initialSize: size,
      scrollback: scrollback
    )
  }
}

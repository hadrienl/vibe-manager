import Foundation
import Testing
import VibeApplication
import VibeDomain

@testable import VibeTerminal

@Test("The default login-shell spec starts a real interactive shell")
func startsTheLoginShell() async throws {
  let spec = TerminalSpec.loginShell(
    workingDirectoryURL: URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
  )
  let session = try PTYTerminalSession.start(id: SessionID(), spec: spec)
  let observer = await TerminalObserver.attach(to: session)

  await session.write("printf 'SHELL_READY\\n'\n")

  #expect(await observer.waitForText("SHELL_READY", occurrences: 2))
  await session.stop(gracePeriod: .seconds(3))
  #expect(await session.state().isFinished)
}

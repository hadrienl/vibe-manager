import Foundation
import VibeTerminal

// The terminal host, run the way the application's binary runs it, with the two differences a test
// needs: any process of the same user may connect — the test binary and this one are signed
// differently — and the idle grace period is short enough to be waited out.
let arguments = CommandLine.arguments
guard let index = arguments.firstIndex(of: TerminalHost.argument), index + 1 < arguments.count
else {
  FileHandle.standardError.write(Data("usage: \(TerminalHost.argument) <directory>\n".utf8))
  exit(64)
}
TerminalHost.run(
  at: TerminalHostLocation(directory: URL(fileURLWithPath: arguments[index + 1])),
  configuration: TerminalHostServer.Configuration(
    verifier: SameUserPeerVerifier(),
    idleGracePeriod: .milliseconds(500)
  )
)

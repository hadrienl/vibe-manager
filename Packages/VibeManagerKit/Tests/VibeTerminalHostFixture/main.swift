import Foundation
import VibeApplication
import VibePersistence
import VibeTerminal

// The terminal host, run the way the application's binary runs it, with the two differences a test
// needs: any process of the same user may connect — the test binary and this one are signed
// differently — and the idle grace period is short enough to be waited out. Given
// `--log-directory`, it writes `host.jsonl` there, as the application's host does.
// `--probe-full-disk-access` makes the fixture answer as the application's binary does, from a
// witness the test controls rather than from the real permission of whoever runs the tests.
FullDiskAccessProbeCommand.runIfRequested(
  probe: TCCFullDiskAccessProbe(
    witnessPath: ProcessInfo.processInfo.environment["TMPDIR", default: "/tmp"]
      + "/vibe-fda-witness"))
let arguments = CommandLine.arguments
guard let index = arguments.firstIndex(of: TerminalHost.argument), index + 1 < arguments.count
else {
  FileHandle.standardError.write(Data("usage: \(TerminalHost.argument) <directory>\n".utf8))
  exit(64)
}
var diagnostics = Diagnostics.disabled
if let logIndex = arguments.firstIndex(of: TerminalHost.logDirectoryArgument),
  logIndex + 1 < arguments.count
{
  diagnostics =
    Diagnostics.standard(
      location: DiagnosticsLocation(
        directory: URL(fileURLWithPath: arguments[logIndex + 1], isDirectory: true)),
      origin: .host
    ).0
}
let location = TerminalHostLocation(directory: URL(fileURLWithPath: arguments[index + 1]))
TerminalHost.run(
  at: location,
  configuration: TerminalHostServer.Configuration(
    verifier: SameUserPeerVerifier(),
    idleGracePeriod: .milliseconds(500),
    diagnostics: diagnostics,
    // Granted when the test leaves a witness beside the socket.
    fullDiskAccess: TCCFullDiskAccessProbe(
      witnessPath: location.directory.appendingPathComponent("fda-witness").path)
  )
)

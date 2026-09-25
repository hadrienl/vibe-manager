import Darwin
import Foundation
import VibeBrowser
import VibeTerminal

// The bridge and the `vibe` command, run the way the application's binary runs them, except that
// any process of the same user is taken for the application: the test binary is not signed as
// this one.
let arguments = CommandLine.arguments
guard arguments.count >= 2 else { exit(64) }
signal(SIGPIPE, SIG_IGN)
switch arguments[1] {
case BrowserBridge.commandLineFlag:
  exit(
    BrowserCommandLine.run(
      Array(arguments.dropFirst(2)), environment: ProcessInfo.processInfo.environment,
      verifier: SameUserPeerVerifier()))
case BrowserBridge.bridgeFlag where arguments.count >= 3:
  BrowserBridge.runBridge(socketPath: arguments[2], verifier: SameUserPeerVerifier())
default:
  // The tests of the channel start it with the socket alone.
  BrowserBridge.runBridge(socketPath: arguments[1], verifier: SameUserPeerVerifier())
}

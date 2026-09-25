import Darwin
import Foundation
import VibeBrowser
import VibeTerminal

// The bridge, run the way the application's binary runs it, except that any process of the same
// user is taken for the application: the test binary is not signed as this one.
guard CommandLine.arguments.count >= 2 else { exit(64) }
signal(SIGPIPE, SIG_IGN)
BrowserBridge.runBridge(socketPath: CommandLine.arguments[1], verifier: SameUserPeerVerifier())

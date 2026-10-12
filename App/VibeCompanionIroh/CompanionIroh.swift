import CompanionCore
import Foundation
import IrohLib
import os

/// What the Mac's agent and the iPhone share of iroh (#368), compiled into both: the echo's ALPN,
/// the journal, and how a path is read. Not in CompanionKit, so that its tests and the application
/// never fetch iroh's 44 MB.
///
/// No watcher: in IrohLib 1.1.0, `watchPaths`, `watchHomeRelay` and the others spawn a Tokio task
/// from a synchronous call, outside any runtime, and the process stops on a Rust panic ("there is
/// no reactor running"). Paths and relay are polled instead: cheap, local reads.
enum CompanionIroh {
  static let logger = Logger(subsystem: "eu.hadrien.VibeManager.companion", category: "iroh")
  static let alpn = Data(CompanionEcho.alpn.utf8)

  /// n0's preset: their public relays (Community, without an account, for development) and their
  /// address lookup. A relay only helps to punch the hole, and carries the data only when that
  /// fails.
  static func options(secretKey: Data? = nil, alpns: [Data]? = nil) -> EndpointOptions {
    EndpointOptions(preset: presetN0(), secretKey: secretKey, alpns: alpns)
  }

  static func pathKind(_ paths: [PathSnapshot]) -> CompanionPathKind {
    CompanionPathKind.selected(among: paths.map { ($0.isSelected, $0.isRelay) })
  }

  /// What tells one selected path from another: a change of it is what the journal notes.
  static func selection(_ paths: [PathSnapshot]) -> String? {
    paths.first(where: \.isSelected).map { "\($0.isRelay ? "relay" : "direct") \($0.remoteAddr)" }
  }

  /// The selected path, as the journal says it: its kind and the address on the other end — an
  /// `ip:port`, or the relay's URL.
  static func describe(_ paths: [PathSnapshot]) -> String {
    guard let path = paths.first(where: \.isSelected) else { return "no path selected" }
    return "\(path.isRelay ? "relay" : "direct") \(path.remoteAddr), rtt \(path.rttMs) ms"
  }

  /// What iroh's errors say, which `localizedDescription` would not.
  static func describe(_ error: any Error) -> String {
    (error as? IrohError)?.message() ?? String(describing: error)
  }
}

import AppKit

/// Reveals and opens what a session's notes link to (#186).
@MainActor
protocol FileOpening: AnyObject {
  func reveal(_ url: URL)
  /// Opens `url` with its default application. False when the system refused.
  func open(_ url: URL) async -> Bool
}

/// `FileOpening` over `NSWorkspace`.
@MainActor
final class WorkspaceFileOpener: FileOpening {
  private let workspace = NSWorkspace.shared

  func reveal(_ url: URL) {
    workspace.activateFileViewerSelecting([url])
  }

  func open(_ url: URL) async -> Bool {
    // Opens outside: an address the caller checked first (notes: `NotesLinks`).
    workspace.open(url)
  }
}

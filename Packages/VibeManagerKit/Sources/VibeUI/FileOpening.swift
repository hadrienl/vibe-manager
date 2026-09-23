import AppKit
import VibeApplication

/// Reveals, opens and copies what the inspector lists. The application never acts on Git: these
/// are the only things a row can do.
@MainActor
protocol FileOpening: AnyObject {
  func exists(_ url: URL) -> Bool
  func reveal(_ url: URL)
  /// False when the system refused: the application is gone, or the file is.
  func open(_ url: URL, with editor: EditorChoice) async -> Bool
  /// The editor's name, or `nil` when it is no longer installed.
  func name(of editor: EditorChoice) -> String?
  /// The known editors installed on this Mac.
  func installedEditors() -> [KnownEditor]
  func copy(_ text: String)
}

/// `FileOpening` over `NSWorkspace` and the general pasteboard.
@MainActor
final class WorkspaceFileOpener: FileOpening {
  private let workspace = NSWorkspace.shared

  func exists(_ url: URL) -> Bool {
    FileManager.default.fileExists(atPath: url.path)
  }

  func reveal(_ url: URL) {
    workspace.activateFileViewerSelecting([url])
  }

  func open(_ url: URL, with editor: EditorChoice) async -> Bool {
    switch editor {
    case .defaultApplication:
      return workspace.open(url)
    case .application(let identifier):
      guard let application = workspace.urlForApplication(withBundleIdentifier: identifier) else {
        return false
      }
      // The completion handler, not the async variant: that one sends `NSWorkspace`, which is not
      // Sendable, off the main actor, and Swift 6.1 refuses it.
      return await withCheckedContinuation { continuation in
        workspace.open(
          [url], withApplicationAt: application, configuration: NSWorkspace.OpenConfiguration()
        ) { _, error in
          continuation.resume(returning: error == nil)
        }
      }
    }
  }

  func name(of editor: EditorChoice) -> String? {
    switch editor {
    case .defaultApplication:
      return "the default application"
    case .application(let identifier):
      guard let url = workspace.urlForApplication(withBundleIdentifier: identifier) else {
        return nil
      }
      if let known = KnownEditor.catalog.first(where: { $0.bundleIdentifier == identifier }) {
        return known.name
      }
      return FileManager.default.displayName(atPath: url.path)
        .replacingOccurrences(of: ".app", with: "")
    }
  }

  func installedEditors() -> [KnownEditor] {
    KnownEditor.catalog.filter {
      workspace.urlForApplication(withBundleIdentifier: $0.bundleIdentifier) != nil
    }
  }

  func copy(_ text: String) {
    let pasteboard = NSPasteboard.general
    pasteboard.clearContents()
    pasteboard.setString(text, forType: .string)
  }
}

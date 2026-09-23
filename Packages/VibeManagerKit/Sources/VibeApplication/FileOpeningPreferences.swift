/// Where a changed file listed in the inspector is opened.
///
/// Nothing is opened in an application the user did not choose: without a choice, a file is only
/// revealed in the Finder.
public enum EditorChoice: Hashable, Sendable, Codable {
  /// Whatever application the file's type opens with.
  case defaultApplication
  /// One application, named by its bundle identifier.
  case application(bundleIdentifier: String)
}

/// The editor chosen in the settings. Read synchronously, at the moment a row is activated.
@MainActor
public protocol FileOpeningPreferences: AnyObject {
  var editor: EditorChoice? { get set }
}

/// Kept for this run only. What a workspace assembled without the system around it uses.
@MainActor
public final class InMemoryFileOpeningPreferences: FileOpeningPreferences {
  public var editor: EditorChoice?

  public init(editor: EditorChoice? = nil) {
    self.editor = editor
  }
}

/// The code editors the settings offer by name, when they are installed.
///
/// A closed list rather than every application that claims to open text: the few hundred of those
/// on a developer's Mac would bury the half-dozen anyone means. Anything else is chosen with
/// "Other…".
public struct KnownEditor: Hashable, Sendable {
  public let name: String
  public let bundleIdentifier: String

  public init(name: String, bundleIdentifier: String) {
    self.name = name
    self.bundleIdentifier = bundleIdentifier
  }

  public static let catalog: [KnownEditor] = [
    KnownEditor(name: "Visual Studio Code", bundleIdentifier: "com.microsoft.VSCode"),
    KnownEditor(name: "Cursor", bundleIdentifier: "com.todesktop.230313mzl4w4u92"),
    KnownEditor(name: "Zed", bundleIdentifier: "dev.zed.Zed"),
    KnownEditor(name: "Xcode", bundleIdentifier: "com.apple.dt.Xcode"),
    KnownEditor(name: "Sublime Text", bundleIdentifier: "com.sublimetext.4"),
    KnownEditor(name: "Nova", bundleIdentifier: "com.panic.Nova"),
    KnownEditor(name: "BBEdit", bundleIdentifier: "com.barebones.bbedit"),
    KnownEditor(name: "IntelliJ IDEA", bundleIdentifier: "com.jetbrains.intellij"),
    KnownEditor(name: "WebStorm", bundleIdentifier: "com.jetbrains.WebStorm"),
  ]
}

import AppKit
import Foundation
import Observation
import SwiftUI
import UniformTypeIdentifiers
import VibeApplication

/// The export of a diagnostics archive, from its preview to the file the user saves.
///
/// Nothing leaves the Mac: the archive is built from exactly the text the sheet shows, and it is
/// written where the user chooses, by the user. There is no upload and no mail.
@MainActor
@Observable
public final class DiagnosticsExportModel: Identifiable {
  public enum State: Equatable {
    case collecting
    case ready
    case saved(fileName: String)
    case failed(String)
  }

  public nonisolated let id = UUID()
  public private(set) var state: State = .collecting
  public private(set) var files: [DiagnosticFile] = []
  public private(set) var preview = ""
  public private(set) var createdAt = Date()

  private let archive: @Sendable ([DiagnosticFile], Date) -> Data
  private let diagnostics: Diagnostics

  public init(
    archive: @escaping @Sendable ([DiagnosticFile], Date) -> Data,
    diagnostics: Diagnostics = .disabled
  ) {
    self.archive = archive
    self.diagnostics = diagnostics
  }

  /// Builds the files and their preview from a snapshot.
  public func load(_ snapshot: DiagnosticSnapshot) {
    createdAt = snapshot.createdAt
    files = DiagnosticArchive.files(from: snapshot)
    preview = DiagnosticArchive.preview(of: files)
    state = .ready
  }

  public var suggestedFileName: String {
    DiagnosticArchive.suggestedFileName(at: createdAt)
  }

  public var totalBytes: Int {
    files.reduce(0) { $0 + $1.contents.count }
  }

  /// Writes the archive of the files on screen to `url`, owner only.
  public func save(to url: URL) {
    let data = archive(files, createdAt)
    do {
      try data.write(to: url, options: .atomic)
      try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
      diagnostics.record(
        .lifecycle, .notice, "diagnostics.exported",
        ["files": .count(files.count), "bytes": .bytes(data.count)])
      state = .saved(fileName: url.lastPathComponent)
    } catch {
      var fields: [(name: StaticString, value: DiagnosticValue)] = []
      if let code = DiagnosticValue.posixCode(of: error) { fields.append(("errno", code)) }
      diagnostics.log.record(
        DiagnosticEvent(.lifecycle, .error, "diagnostics.exportFailed", fields: fields))
      state = .failed(
        (error as? LocalizedError)?.errorDescription
          ?? String(localized: "The file could not be saved.", bundle: .module))
    }
  }
}

/// Shows the export exactly as it will be written, and saves it.
struct DiagnosticsExportSheet: View {
  let model: DiagnosticsExportModel
  let close: () -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      Text("Export Diagnostics", bundle: .module)
        .font(.title2.weight(.semibold))
      Text(
        """
        This is everything the file will contain. Read it, search it with ⌘F, then save it and \
        attach it to a report yourself: nothing is sent.
        """,
        bundle: .module
      )
      .fixedSize(horizontal: false, vertical: true)
      // `DiagnosticArchive.exclusions`, which the archive itself carries in English.
      Text(
        "Not included: what the terminals showed, prompts, notes, and the names of sessions and folders.",
        bundle: .module
      )
      .font(.callout)
      .foregroundStyle(.secondary)
      .fixedSize(horizontal: false, vertical: true)

      Group {
        switch model.state {
        case .collecting:
          ProgressView {
            Text("Gathering diagnostics…", bundle: .module)
          }
          .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .ready, .saved, .failed:
          ReadOnlyTextView(text: model.preview)
            .accessibilityLabel(Text("Diagnostics preview", bundle: .module))
            .accessibilityIdentifier("diagnostics-preview")
        }
      }
      .frame(minHeight: 320)
      .overlay(RoundedRectangle(cornerRadius: 6).stroke(.separator))

      HStack {
        switch model.state {
        case .saved(let fileName):
          Label {
            Text("Saved as \(fileName).", bundle: .module, comment: "The name of the saved file.")
          } icon: {
            Image(systemName: "checkmark.circle.fill")
          }
          .foregroundStyle(.green)
        case .failed(let message):
          Label(message, systemImage: "exclamationmark.triangle.fill")
            .foregroundStyle(.orange)
        case .ready:
          Text(
            String(
              localized: "\(model.files.count) files", bundle: .module,
              comment: "How many files the diagnostics archive holds.")
              + ", "
              + ByteCountFormatter.string(
                fromByteCount: Int64(model.totalBytes), countStyle: .file)
          )
          .foregroundStyle(.secondary)
        case .collecting:
          EmptyView()
        }
        Spacer()
        Button(action: close) {
          if isSaved {
            Text("Done", bundle: .module)
          } else {
            Text("Cancel", bundle: .module)
          }
        }
        .keyboardShortcut(.cancelAction)
        Button(action: save) {
          Text("Save…", bundle: .module)
        }
        .keyboardShortcut(.defaultAction)
        .disabled(model.state == .collecting)
        .accessibilityIdentifier("diagnostics-save")
      }
    }
    .padding(20)
    .frame(minWidth: 640, idealWidth: 760, minHeight: 520, idealHeight: 620)
  }

  private var isSaved: Bool {
    if case .saved = model.state { return true }
    return false
  }

  private func save() {
    let panel = NSSavePanel()
    panel.nameFieldStringValue = model.suggestedFileName
    panel.allowedContentTypes = [.zip]
    panel.canCreateDirectories = true
    guard panel.runModal() == .OK, let url = panel.url else { return }
    model.save(to: url)
  }
}

/// A text the user can scroll, select, copy and search, and not change.
struct ReadOnlyTextView: NSViewRepresentable {
  let text: String

  func makeNSView(context: Context) -> NSScrollView {
    let scrollView = NSTextView.scrollableTextView()
    guard let textView = scrollView.documentView as? NSTextView else { return scrollView }
    textView.isEditable = false
    textView.isSelectable = true
    textView.usesFindBar = true
    textView.isIncrementalSearchingEnabled = true
    textView.font = .monospacedSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular)
    textView.textContainerInset = NSSize(width: 6, height: 6)
    textView.string = text
    return scrollView
  }

  func updateNSView(_ scrollView: NSScrollView, context: Context) {
    guard let textView = scrollView.documentView as? NSTextView, textView.string != text else {
      return
    }
    textView.string = text
  }
}

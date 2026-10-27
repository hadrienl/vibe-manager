import AppKit
import SwiftUI
import VibeApplication
import VibeDomain

/// Settings › Worktrees (#432): the path for every repository, and the repositories with their own.
struct WorktreesSettingsView: View {
  @Bindable var worktrees: WorktreesModel
  /// The main repositories of the sessions: the examples of the preview, and the choices of a new
  /// exception.
  let repositories: [String]
  @State private var editing: WorktreeExceptionEditing?

  var body: some View {
    Form {
      Section {
        WorktreeLocationEditor(
          location: $worktrees.settings.general,
          examples: WorktreeLocationExample.examples(repositories: repositories))
      } header: {
        Text(
          "Worktree Location", bundle: .module, comment: "A section of Settings › Worktrees.")
      } footer: {
        Text(
          "Vibe Manager gives this path to every agent, which creates the worktree of a task there itself. It applies to new worktrees only: those of open sessions stay where they are.",
          bundle: .module
        )
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
      }
      Section {
        ForEach(worktrees.settings.exceptions.keys.sorted(), id: \.self) { repository in
          exceptionRow(repository)
        }
        Button {
          editing = WorktreeExceptionEditing(
            repository: repositories.first { worktrees.settings.exceptions[$0] == nil },
            location: worktrees.settings.general, isNew: true)
        } label: {
          Text("Add…", bundle: .module, comment: "Settings › Worktrees: adds a project's own path.")
        }
        .accessibilityIdentifier("settings-worktrees-add-exception")
      } header: {
        Text(
          "Projects with Their Own Location", bundle: .module,
          comment: "A section of Settings › Worktrees.")
      } footer: {
        Text("Replaces the path above for one repository.", bundle: .module)
          .foregroundStyle(.secondary)
      }
    }
    .formStyle(.grouped)
    .sheet(item: $editing) { editing in
      WorktreeExceptionSheet(
        editing: editing, repositories: repositories,
        taken: Set(worktrees.settings.exceptions.keys)
      ) { repository, location in
        if !editing.isNew, let old = editing.repository, old != repository {
          worktrees.settings.exceptions[old] = nil
        }
        worktrees.settings.exceptions[repository] = location
      }
    }
  }

  private func exceptionRow(_ repository: String) -> some View {
    let location = worktrees.settings.exceptions[repository] ?? .default
    return HStack {
      Button {
        editing = WorktreeExceptionEditing(
          repository: repository, location: location, isNew: false)
      } label: {
        VStack(alignment: .leading, spacing: 2) {
          Text(verbatim: (repository as NSString).lastPathComponent)
          Text(
            verbatim: location.resolved([
              .repository: WorktreeLocationExample.abbreviated(repository),
              .project: (repository as NSString).lastPathComponent,
            ])
          )
          .font(.caption.monospaced())
          .foregroundStyle(.secondary)
          .lineLimit(1)
          .truncationMode(.middle)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      Button {
        worktrees.settings.exceptions[repository] = nil
      } label: {
        Image(systemName: "minus")
      }
      .buttonStyle(.borderless)
      .accessibilityLabel(Text("Remove", bundle: .module))
    }
  }
}

/// The path, as a menu of presets, a field of text and variables, a palette, and a preview.
struct WorktreeLocationEditor: View {
  @Binding var location: WorktreeLocation
  let examples: [WorktreeLocationExample]

  private enum Choice: Hashable {
    case preset(WorktreeLocation.Preset)
    case custom
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      HStack {
        Picker(
          selection: Binding(
            get: { location.preset.map(Choice.preset) ?? .custom },
            set: { if case .preset(let preset) = $0 { location = preset.location } })
        ) {
          ForEach(WorktreeLocation.Preset.allCases, id: \.self) { preset in
            Text(Self.name(of: preset)).tag(Choice.preset(preset))
          }
          Text("Custom", bundle: .module, comment: "Settings › Worktrees: a path of the user's own.")
            .tag(Choice.custom)
        } label: {
          Text(
            "Preset", bundle: .module,
            comment: "Settings › Worktrees: the menu of the paths ready to use.")
        }
        .fixedSize()
        .accessibilityIdentifier("settings-worktrees-preset")
        Spacer()
        Button {
          location = .default
        } label: {
          Text("Restore Default", bundle: .module, comment: "Settings › Worktrees.")
        }
        .disabled(location == .default)
      }
      WorktreeTokenField(location: $location)
        .frame(minHeight: 24)
        .accessibilityIdentifier("settings-worktrees-field")
      Text(
        "Click a variable to add it, type text between them, drag a variable to move it.",
        bundle: .module
      )
      .font(.caption)
      .foregroundStyle(.secondary)
      WorktreeVariablePalette(example: examples[0]) { variable in
        location = WorktreeLocation(parts: location.parts + [.variable(variable)])
      }
      Divider()
      Text("Preview", bundle: .module, comment: "Settings › Worktrees: the path resolved.")
        .font(.headline)
      VStack(alignment: .leading, spacing: 4) {
        ForEach(examples, id: \.self) { example in
          HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(verbatim: example.label)
              .font(.caption)
              .foregroundStyle(.secondary)
            preview(for: example)
              .font(.callout.monospaced())
              .lineLimit(1)
              .truncationMode(.head)
              .textSelection(.enabled)
          }
        }
      }
      .padding(8)
      .frame(maxWidth: .infinity, alignment: .leading)
      .background(.background.secondary, in: RoundedRectangle(cornerRadius: 7))
      status
    }
  }

  private func preview(for example: WorktreeLocationExample) -> Text {
    let values = example.values()
    var text = AttributedString()
    for part in location.parts {
      switch part {
      case .text(let string):
        text += AttributedString(string)
      case .variable(let variable):
        var value = AttributedString(values[variable] ?? "")
        value.foregroundColor = .accentColor
        value.backgroundColor = .accentColor.opacity(0.15)
        text += value
      }
    }
    return Text(text)
  }

  @ViewBuilder private var status: some View {
    switch location.warning {
    case nil:
      Label {
        Text("Each task will have its own folder.", bundle: .module)
      } icon: {
        Image(systemName: "checkmark.circle.fill")
      }
      .foregroundStyle(.green)
      .font(.callout)
    case .some(let warning):
      Label {
        Text(Self.message(warning))
      } icon: {
        Image(systemName: "exclamationmark.triangle.fill")
      }
      .foregroundStyle(.orange)
      .font(.callout)
      .fixedSize(horizontal: false, vertical: true)
      .accessibilityIdentifier("settings-worktrees-warning")
    }
  }

  static func message(_ warning: WorktreeLocation.Warning) -> LocalizedStringResource {
    switch warning {
    case .empty:
      LocalizedStringResource(
        "The path is empty: the agents will choose where to create their worktrees.",
        bundle: .module)
    case .notDistinctive:
      LocalizedStringResource(
        "Add Branch, Ticket or Session: otherwise two tasks would share the same folder.",
        bundle: .module)
    case .notAbsolute:
      LocalizedStringResource(
        "The path must start with ~, / or the Repository variable.", bundle: .module)
    }
  }

  static func name(of preset: WorktreeLocation.Preset) -> LocalizedStringResource {
    switch preset {
    case .insideRepository:
      LocalizedStringResource(
        "In the repository, .claude/worktrees", bundle: .module,
        comment: "Settings › Worktrees: a path ready to use.")
    case .besideRepository:
      LocalizedStringResource(
        "Beside the repository", bundle: .module,
        comment: "Settings › Worktrees: a path ready to use.")
    case .commonFolder:
      LocalizedStringResource(
        "Common folder ~/Worktrees", bundle: .module,
        comment: "Settings › Worktrees: a path ready to use.")
    }
  }

  static func name(of variable: WorktreeLocation.Variable) -> LocalizedStringResource {
    switch variable {
    case .repository:
      LocalizedStringResource(
        "Repository", bundle: .module,
        comment: "Settings › Worktrees: a variable of the path, the main repository's folder.")
    case .project:
      LocalizedStringResource(
        "Project", bundle: .module,
        comment: "Settings › Worktrees: a variable of the path, the repository's name.")
    case .branch:
      LocalizedStringResource(
        "Branch", bundle: .module, comment: "Settings › Worktrees: a variable of the path.")
    case .ticket:
      LocalizedStringResource(
        "Ticket", bundle: .module, comment: "Settings › Worktrees: a variable of the path.")
    case .session:
      LocalizedStringResource(
        "Session", bundle: .module, comment: "Settings › Worktrees: a variable of the path.")
    case .agent:
      LocalizedStringResource(
        "Agent", bundle: .module, comment: "Settings › Worktrees: a variable of the path.")
    case .date:
      LocalizedStringResource(
        "Date", bundle: .module, comment: "Settings › Worktrees: a variable of the path.")
    }
  }
}

/// The variables, each with what it would be for the first example: a click adds it at the end.
private struct WorktreeVariablePalette: View {
  let example: WorktreeLocationExample
  let add: (WorktreeLocation.Variable) -> Void

  var body: some View {
    let values = example.values()
    WrappingStack(spacing: 6) {
      ForEach(WorktreeLocation.Variable.allCases, id: \.self) { variable in
        Button {
          add(variable)
        } label: {
          VStack(alignment: .leading, spacing: 2) {
            Text(WorktreeLocationEditor.name(of: variable))
              .font(.caption.weight(.semibold))
              .padding(.horizontal, 6)
              .padding(.vertical, 1)
              .background(.tint.opacity(0.18), in: RoundedRectangle(cornerRadius: 4))
              .foregroundStyle(.tint)
            Text(verbatim: values[variable] ?? "")
              .font(.caption2)
              .foregroundStyle(.secondary)
              .lineLimit(1)
          }
          .padding(.horizontal, 7)
          .padding(.vertical, 4)
          .overlay(
            RoundedRectangle(cornerRadius: 6).strokeBorder(
              .separator, style: StrokeStyle(lineWidth: 1, dash: [3, 2])))
          .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("settings-worktrees-variable-\(variable.rawValue)")
      }
    }
  }
}

/// Lays its views out in lines, as many on each as fit.
private struct WrappingStack: Layout {
  var spacing: CGFloat

  func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
    let frames = frames(width: proposal.width ?? .infinity, subviews: subviews)
    return CGSize(
      width: frames.map(\.maxX).max() ?? 0, height: frames.map(\.maxY).max() ?? 0)
  }

  func placeSubviews(
    in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()
  ) {
    for (frame, subview) in zip(frames(width: bounds.width, subviews: subviews), subviews) {
      subview.place(
        at: CGPoint(x: bounds.minX + frame.minX, y: bounds.minY + frame.minY),
        proposal: ProposedViewSize(frame.size))
    }
  }

  private func frames(width: CGFloat, subviews: Subviews) -> [CGRect] {
    var frames: [CGRect] = []
    var point = CGPoint.zero
    var lineHeight: CGFloat = 0
    for subview in subviews {
      let size = subview.sizeThatFits(.unspecified)
      if point.x > 0, point.x + size.width > width {
        point = CGPoint(x: 0, y: point.y + lineHeight + spacing)
        lineHeight = 0
      }
      frames.append(CGRect(origin: point, size: size))
      point.x += size.width + spacing
      lineHeight = max(lineHeight, size.height)
    }
    return frames
  }
}

// MARK: - Exceptions

struct WorktreeExceptionEditing: Identifiable {
  let id = UUID()
  var repository: String?
  var location: WorktreeLocation
  var isNew: Bool
}

/// A repository and its own path: chosen among the sessions' repositories, or in the Finder.
private struct WorktreeExceptionSheet: View {
  let editing: WorktreeExceptionEditing
  let repositories: [String]
  /// The repositories that have their own path already: not offered again.
  let taken: Set<String>
  let save: (String, WorktreeLocation) -> Void
  @Environment(\.dismiss) private var dismiss
  @State private var repository: String?
  @State private var location: WorktreeLocation = .default
  @State private var chosen: [String] = []

  var body: some View {
    VStack(alignment: .leading, spacing: 14) {
      Picker(
        selection: Binding(
          get: { repository ?? "" },
          set: { value in
            if value == Self.other {
              chooseInFinder()
            } else {
              repository = value.isEmpty ? nil : value
            }
          })
      ) {
        if repository == nil {
          Text("Choose…", bundle: .module).tag("")
        }
        ForEach(choices, id: \.self) { path in
          Text(verbatim: "\((path as NSString).lastPathComponent) — \(WorktreeLocationExample.abbreviated(path))")
            .tag(path)
        }
        Divider()
        Text("Other…", bundle: .module, comment: "Settings › Worktrees: chooses a repository in the Finder.")
          .tag(Self.other)
      } label: {
        Text("Repository", bundle: .module)
      }
      .accessibilityIdentifier("settings-worktrees-exception-repository")
      WorktreeLocationEditor(
        location: $location,
        examples: WorktreeLocationExample.examples(
          repositories: (repository.map { [$0] } ?? []) + repositories))
      HStack {
        Spacer()
        Button {
          dismiss()
        } label: {
          Text("Cancel", bundle: .module)
        }
        .keyboardShortcut(.cancelAction)
        Button {
          if let repository { save(repository, location) }
          dismiss()
        } label: {
          if editing.isNew {
            Text("Add", bundle: .module, comment: "Settings › Worktrees: keeps a project's own path.")
          } else {
            Text("Save", bundle: .module)
          }
        }
        .keyboardShortcut(.defaultAction)
        .disabled(repository == nil)
      }
    }
    .padding(20)
    .frame(width: 560)
    .onAppear {
      repository = editing.repository
      location = editing.location
    }
  }

  private static let other = "\u{0}other"

  private var choices: [String] {
    var paths = (repositories + chosen).filter { !taken.contains($0) || $0 == editing.repository }
    if let repository, !paths.contains(repository) { paths.append(repository) }
    return paths
  }

  private func chooseInFinder() {
    let panel = NSOpenPanel()
    panel.canChooseDirectories = true
    panel.canChooseFiles = false
    panel.allowsMultipleSelection = false
    guard panel.runModal() == .OK, let url = panel.url else { return }
    let path = WorktreeInstructions.mainRepository(of: url.path)
    if !chosen.contains(path) { chosen.append(path) }
    repository = path
  }
}

// MARK: - Token field

/// The path as `NSTokenField` shows it: text as text, each variable as a token. A token is moved
/// by dragging it, removed with ⌫; the text between them is typed, and edited by double-clicking.
struct WorktreeTokenField: NSViewRepresentable {
  @Binding var location: WorktreeLocation

  func makeNSView(context: Context) -> NSTokenField {
    let field = NSTokenField()
    // No character ends a token: what is typed stays text.
    field.tokenizingCharacterSet = CharacterSet(charactersIn: "\u{1}")
    field.completionDelay = .greatestFiniteMagnitude
    field.font = .monospacedSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
    field.delegate = context.coordinator
    field.objectValue = Coordinator.objects(location.parts)
    field.cell?.wraps = true
    field.cell?.isScrollable = false
    field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    return field
  }

  func updateNSView(_ field: NSTokenField, context: Context) {
    context.coordinator.binding = $location
    guard Coordinator.location(of: field.objectValue) != location else { return }
    field.objectValue = Coordinator.objects(location.parts)
  }

  func makeCoordinator() -> Coordinator { Coordinator(binding: $location) }

  /// A variable in the field: text is an `NSString`.
  final class VariableToken: NSObject {
    let variable: WorktreeLocation.Variable
    init(_ variable: WorktreeLocation.Variable) { self.variable = variable }
  }

  @MainActor
  final class Coordinator: NSObject, NSTokenFieldDelegate {
    var binding: Binding<WorktreeLocation>
    private static let pasteboardType = NSPasteboard.PasteboardType(
      "com.hadrienl.vibe-manager.worktree-location")

    init(binding: Binding<WorktreeLocation>) { self.binding = binding }

    static func objects(_ parts: [WorktreeLocation.Part]) -> [Any] {
      parts.map { part -> Any in
        switch part {
        case .text(let text): text as NSString
        case .variable(let variable): VariableToken(variable)
        }
      }
    }

    static func location(of value: Any?) -> WorktreeLocation {
      let objects = (value as? [Any]) ?? (value as? String).map { [$0] } ?? []
      return WorktreeLocation(
        parts: objects.flatMap { object -> [WorktreeLocation.Part] in
          if let token = object as? VariableToken { return [.variable(token.variable)] }
          // Text typed as `{branch}` is a variable too.
          return WorktreeLocation(template: "\(object)").parts
        })
    }

    func controlTextDidChange(_ notification: Notification) {
      guard let field = notification.object as? NSTokenField else { return }
      // The text being typed is not in `objectValue` yet: read the field editor's.
      var value = field.objectValue
      if let editor = field.currentEditor(), let objects = value as? [Any] {
        value = objects.isEmpty && !editor.string.isEmpty ? [editor.string] : objects
      }
      let location = Self.location(of: value)
      if location != binding.wrappedValue { binding.wrappedValue = location }
    }

    func controlTextDidEndEditing(_ notification: Notification) {
      guard let field = notification.object as? NSTokenField else { return }
      let location = Self.location(of: field.objectValue)
      if location != binding.wrappedValue { binding.wrappedValue = location }
      field.objectValue = Self.objects(location.parts)
    }

    func tokenField(
      _ tokenField: NSTokenField, displayStringForRepresentedObject representedObject: Any
    ) -> String? {
      if let token = representedObject as? VariableToken {
        return String(localized: WorktreeLocationEditor.name(of: token.variable))
      }
      return "\(representedObject)"
    }

    func tokenField(
      _ tokenField: NSTokenField, styleForRepresentedObject representedObject: Any
    ) -> NSTokenField.TokenStyle {
      representedObject is VariableToken ? .rounded : .none
    }

    func tokenField(
      _ tokenField: NSTokenField, representedObjectForEditing editingString: String
    ) -> Any? {
      editingString as NSString
    }

    func tokenField(
      _ tokenField: NSTokenField, editingStringForRepresentedObject representedObject: Any
    ) -> String? {
      representedObject is VariableToken ? nil : "\(representedObject)"
    }

    func tokenField(
      _ tokenField: NSTokenField, writeRepresentedObjects objects: [Any], to pboard: NSPasteboard
    ) -> Bool {
      let template = Self.location(of: objects).template
      pboard.declareTypes([Self.pasteboardType, .string], owner: nil)
      pboard.setString(template, forType: Self.pasteboardType)
      pboard.setString(template, forType: .string)
      return true
    }

    func tokenField(_ tokenField: NSTokenField, readFrom pboard: NSPasteboard) -> [Any]? {
      guard
        let template = pboard.string(forType: Self.pasteboardType)
          ?? pboard.string(forType: .string)
      else { return nil }
      return Self.objects(WorktreeLocation(template: template).parts)
    }
  }
}

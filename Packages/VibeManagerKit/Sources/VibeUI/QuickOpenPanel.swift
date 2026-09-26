import AppKit
import SwiftUI
import VibeApplication
import VibeDomain

/// Open Quickly, ⌘P (#37): a floating panel in the upper third of the window, over the three
/// columns, like Xcode's.
///
/// An overlay of the window rather than a sheet: the window shows one sheet at a time, a sheet is
/// modal and animated, and this one closes with a click anywhere else. The keyboard stays in the
/// field the whole time; the arrows, Return and Escape reach the list from there.
struct QuickOpenPanel: View {
  let model: AppModel

  static let width: CGFloat = 640
  static let rowHeight: CGFloat = 44
  static let visibleRows = 10

  private var palette: QuickOpenModel { model.quickOpen }

  var body: some View {
    ZStack(alignment: .top) {
      // A click outside the panel closes it, and goes nowhere else.
      Color.clear
        .contentShape(Rectangle())
        .onTapGesture { palette.dismiss(restoringFocus: true) }
        .accessibilityHidden(true)

      VStack(spacing: 0) {
        HStack(spacing: 8) {
          Image(systemName: "magnifyingglass")
            .foregroundStyle(.secondary)
            .accessibilityHidden(true)
          QuickOpenField(
            text: palette.text,
            selectAllRequest: palette.selectAllRequest,
            placeholder: String(
              localized: "Ticket, pull or merge request URL, branch, folder or title",
              bundle: .module, comment: "The placeholder of Open Quickly's field."),
            accessibilityLabel: String(
              localized: "Open Quickly", bundle: .module,
              comment: "The name of the palette that finds a session, for VoiceOver."),
            changed: { palette.setText($0) },
            moved: { move(by: $0) },
            confirmed: { model.openQuickOpenSelection() },
            cancelled: { palette.dismiss(restoringFocus: true) })
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)

        Divider()
        content
        footer
      }
      .frame(width: Self.width)
      .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
      .overlay {
        RoundedRectangle(cornerRadius: 12, style: .continuous)
          .strokeBorder(Color(nsColor: .separatorColor))
      }
      .shadow(color: .black.opacity(0.25), radius: 24, y: 8)
      .padding(.top, 72)
      .padding(.horizontal, 16)
      .accessibilityElement(children: .contain)
      .accessibilityLabel(
        Text("Open Quickly", bundle: .module, comment: "The name of the palette that finds a session, for VoiceOver."))
      .accessibilityIdentifier("quick-open")
      .accessibilityAddTraits(.isModal)
    }
  }

  // MARK: - Results

  @ViewBuilder private var content: some View {
    let results = palette.results
    if results.isEmpty {
      if let answer = palette.answer, !answer.query.isEmpty {
        VStack(alignment: .leading, spacing: 4) {
          Text(
            verbatim: answer.unmatchedResource.flatMap(QuickOpenPresentation.unused)
              ?? QuickOpenPresentation.noMatch(answer.query.text))
          .font(.body)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .accessibilityIdentifier("quick-open-empty")
      }
    } else {
      VStack(alignment: .leading, spacing: 0) {
        if results.first?.rank == .recent {
          Text("Recent", bundle: .module, comment: "The header of the latest sessions in Open Quickly.")
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 14)
            .padding(.top, 8)
            .accessibilityAddTraits(.isHeader)
        }
        ScrollViewReader { proxy in
          ScrollView {
            LazyVStack(spacing: 0) {
              ForEach(Array(results.enumerated()), id: \.element.id) { position, result in
                row(result, position: position, count: results.count)
                  .id(result.id)
              }
            }
            .padding(6)
          }
          .frame(height: CGFloat(min(results.count, Self.visibleRows)) * Self.rowHeight + 12)
          .onChange(of: palette.selectedIndex) { _, index in
            guard results.indices.contains(index) else { return }
            proxy.scrollTo(results[index].id)
          }
        }
      }
    }
  }

  @ViewBuilder private func row(_ result: QuickOpenResult, position: Int, count: Int) -> some View
  {
    if let session = model.sessions.first(where: { $0.id == result.sessionID }) {
      let isSelected = position == palette.selectedIndex
      let reason = QuickOpenPresentation.reason(result.reason)
      Button {
        palette.select(result.sessionID)
        model.openQuickOpenSelection()
      } label: {
        HStack(spacing: 10) {
          SessionBadge(appearance: session.appearance, size: 26)
          VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
              Text(QuickOpenPresentation.highlighted(session.name, words: result.highlights))
                .lineLimit(1)
                .truncationMode(.tail)
              Spacer(minLength: 8)
              if result.isArchived {
                Text(verbatim: QuickOpenPresentation.archivedLabel)
                  .font(.caption2.weight(.medium))
                  .padding(.horizontal, 5)
                  .padding(.vertical, 1)
                  .overlay(Capsule().strokeBorder(.secondary.opacity(0.6)))
              }
              Text(verbatim: state(of: session))
                .font(.caption)
                .foregroundStyle(isSelected ? .primary : .secondary)
                .lineLimit(1)
            }
            if let reason {
              Text(QuickOpenPresentation.highlighted(reason, words: result.highlights))
                .font(.caption)
                .foregroundStyle(isSelected ? .primary : .secondary)
                .lineLimit(1)
                .truncationMode(.middle)
            }
          }
        }
        .padding(.horizontal, 8)
        .frame(height: Self.rowHeight)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
          RoundedRectangle(cornerRadius: 7, style: .continuous)
            .fill(isSelected ? Color.accentColor.opacity(0.22) : .clear)
        )
        .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      .accessibilityElement(children: .ignore)
      .accessibilityLabel(Text(verbatim: spoken(result, session: session, position: position, count: count)))
      .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
      .accessibilityIdentifier("quick-open-row")
    }
  }

  @ViewBuilder private var footer: some View {
    let showsHelp = palette.text.isEmpty || (palette.answer != nil && palette.results.isEmpty)
    if palette.indexing != nil || showsHelp {
      Divider()
      VStack(alignment: .leading, spacing: 4) {
        if let indexing = palette.indexing {
          HStack(spacing: 6) {
            ProgressView().controlSize(.mini)
            Text(verbatim: QuickOpenPresentation.indexing(done: indexing.done, total: indexing.total))
          }
        }
        if showsHelp {
          Text(verbatim: QuickOpenPresentation.formats)
        }
      }
      .font(.caption)
      .foregroundStyle(.secondary)
      .frame(maxWidth: .infinity, alignment: .leading)
      .padding(.horizontal, 14)
      .padding(.vertical, 8)
    }
  }

  // MARK: - Words

  /// Its task status, and what its agent is doing while it runs: "In Progress · Needs Input".
  private func state(of session: WorkSession) -> String {
    var parts = [String(localized: session.taskStatus.label)]
    if session.status == .active {
      parts.append(String(localized: model.statusPresentation(for: session).label))
    }
    return parts.joined(separator: " · ")
  }

  private func spoken(
    _ result: QuickOpenResult, session: WorkSession, position: Int, count: Int
  ) -> String {
    QuickOpenPresentation.spokenRow(
      title: session.name, state: state(of: session), reason: result.reason,
      isArchived: result.isArchived, position: position + 1, count: count)
  }

  /// The arrows move through the list while the keyboard stays in the field, so VoiceOver is told
  /// the row reached: nothing else would say it.
  private func move(by offset: Int) {
    let before = palette.selectedIndex
    palette.moveSelection(by: offset)
    guard palette.selectedIndex != before, let result = palette.selectedResult,
      let session = model.sessions.first(where: { $0.id == result.sessionID })
    else { return }
    Announcer.announce(
      spoken(result, session: session, position: palette.selectedIndex, count: palette.results.count))
  }
}

/// The palette's field: AppKit's, so that the arrows, Page Up and Down, ⌃N and ⌃P, Return and
/// Escape arrive as the commands the field editor already knows, instead of being moved through
/// the text.
struct QuickOpenField: NSViewRepresentable {
  let text: String
  let selectAllRequest: Int
  let placeholder: String
  let accessibilityLabel: String
  let changed: (String) -> Void
  let moved: (Int) -> Void
  let confirmed: () -> Void
  let cancelled: () -> Void

  /// How far Page Up and Page Down go.
  static let page = QuickOpenPanel.visibleRows - 1

  func makeCoordinator() -> Coordinator { Coordinator(self) }

  func makeNSView(context: Context) -> NSTextField {
    let field = NSTextField()
    field.isBordered = false
    field.drawsBackground = false
    field.focusRingType = .none
    field.font = .systemFont(ofSize: 20)
    field.placeholderString = placeholder
    field.lineBreakMode = .byTruncatingTail
    field.cell?.usesSingleLineMode = true
    field.delegate = context.coordinator
    field.setAccessibilityLabel(accessibilityLabel)
    field.setAccessibilityIdentifier("quick-open-field")
    field.stringValue = text
    context.coordinator.selectAllRequest = selectAllRequest
    // Once in a window: the keyboard is the palette's from the moment it shows.
    DispatchQueue.main.async { [weak field] in
      guard let field, let window = field.window else { return }
      window.makeFirstResponder(field)
    }
    return field
  }

  func updateNSView(_ field: NSTextField, context: Context) {
    context.coordinator.parent = self
    if field.stringValue != text { field.stringValue = text }
    if context.coordinator.selectAllRequest != selectAllRequest {
      context.coordinator.selectAllRequest = selectAllRequest
      field.window?.makeFirstResponder(field)
      field.currentEditor()?.selectAll(nil)
    }
  }

  @MainActor
  final class Coordinator: NSObject, NSTextFieldDelegate {
    var parent: QuickOpenField
    var selectAllRequest = 0

    init(_ parent: QuickOpenField) {
      self.parent = parent
    }

    func controlTextDidChange(_ notification: Notification) {
      guard let field = notification.object as? NSTextField else { return }
      parent.changed(field.stringValue)
    }

    func control(
      _ control: NSControl, textView: NSTextView, doCommandBy selector: Selector
    ) -> Bool {
      switch selector {
      case #selector(NSResponder.moveUp(_:)):
        parent.moved(-1)
      case #selector(NSResponder.moveDown(_:)):
        parent.moved(1)
      case #selector(NSResponder.pageUp(_:)), #selector(NSResponder.scrollPageUp(_:)):
        parent.moved(-QuickOpenField.page)
      case #selector(NSResponder.pageDown(_:)), #selector(NSResponder.scrollPageDown(_:)):
        parent.moved(QuickOpenField.page)
      case #selector(NSResponder.insertNewline(_:)):
        parent.confirmed()
      case #selector(NSResponder.cancelOperation(_:)):
        parent.cancelled()
      default:
        return false
      }
      return true
    }
  }
}

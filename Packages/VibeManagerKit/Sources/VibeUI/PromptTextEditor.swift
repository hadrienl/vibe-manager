import AppKit
import SwiftUI
import VibeConversationUI
import VibeDomain

/// Where a prompt is written: a plain-text area as tall as what it holds.
///
/// It grows with the lines on screen — wrapped lines included, not only the `\n` — from
/// `minimumLines` up to `maximumLines`, then scrolls inside, so a short prompt is read whole and a
/// long one does not push the rest of the form off the screen. Return goes to the line; the form
/// around it decides what ⌘↩ does — unless it hands an `onSubmit`, which Return then calls, the
/// line being ⇧↩, as in a conversation's composer.
///
/// An `NSTextView` rather than `TextEditor`, which cannot say how tall its content is, or
/// `TextField(axis: .vertical)`, which grows by itself but submits on Return.
public struct PromptTextEditor: View {
  public static let defaultMaximumLines = 10

  @Binding private var text: String
  private let minimumLines: Int
  private let maximumLines: Int
  private let placeholder: String?
  private let accessibilityLabel: String
  private let highlightsPlaceholders: Bool
  private let focusRequested: Bool
  private let isEditable: Bool
  private let isBordered: Bool
  private let onSubmit: (() -> Void)?
  private let onCancel: (() -> Void)?
  /// The list of skills and commands a `/` typed first opens (#219): its keys go first while it
  /// is open.
  private let commands: ComposerCommands?
  @State private var height: CGFloat?

  public init(
    text: Binding<String>,
    minimumLines: Int = 3,
    maximumLines: Int = PromptTextEditor.defaultMaximumLines,
    placeholder: String? = nil,
    accessibilityLabel: String,
    highlightsPlaceholders: Bool = false,
    focusRequested: Bool = false,
    isEditable: Bool = true,
    isBordered: Bool = true,
    onSubmit: (() -> Void)? = nil,
    onCancel: (() -> Void)? = nil,
    commands: ComposerCommands? = nil
  ) {
    self.commands = commands
    _text = text
    self.minimumLines = minimumLines
    self.maximumLines = maximumLines
    self.placeholder = placeholder
    self.accessibilityLabel = accessibilityLabel
    self.highlightsPlaceholders = highlightsPlaceholders
    self.focusRequested = focusRequested
    self.isEditable = isEditable
    self.isBordered = isBordered
    self.onSubmit = onSubmit
    self.onCancel = onCancel
  }

  public var body: some View {
    GrowingTextView(
      text: $text,
      height: $height,
      minimumLines: minimumLines,
      maximumLines: maximumLines,
      accessibilityLabel: accessibilityLabel,
      highlightsPlaceholders: highlightsPlaceholders,
      focusRequested: focusRequested,
      isEditable: isEditable,
      onSubmit: onSubmit,
      onCancel: onCancel,
      commands: commands,
      token: commands?.insertedInvocation
    )
    .frame(height: height ?? PromptTextStyle.height(forLines: minimumLines))
    .overlay(alignment: .topLeading) {
      // What the command inserted expects, dimmed after it until something is typed.
      if let hint = commands?.pendingArgumentHint {
        Text(Self.hinted(text, hint))
          .font(.body)
          .padding(.leading, PromptTextStyle.inset.width + 5)
          .padding(.top, PromptTextStyle.inset.height)
          .allowsHitTesting(false)
          .accessibilityHidden(true)
      }
    }
    .overlay(alignment: .topLeading) {
      if text.isEmpty, let placeholder {
        Text(placeholder)
          .font(.body)
          .foregroundStyle(.tertiary)
          .padding(.leading, PromptTextStyle.inset.width + 5)
          .padding(.top, PromptTextStyle.inset.height)
          .allowsHitTesting(false)
          .accessibilityHidden(true)
      }
    }
    .background(
      isBordered ? Color(nsColor: .textBackgroundColor) : Color.clear,
      in: RoundedRectangle(cornerRadius: 6)
    )
    .overlay {
      if isBordered {
        RoundedRectangle(cornerRadius: 6).strokeBorder(.separator)
      }
    }
  }
}

extension PromptTextEditor {
  /// The text, invisible, then the hint: laid out as the text is, the hint follows its end.
  fileprivate static func hinted(_ text: String, _ hint: String) -> AttributedString {
    var shown = AttributedString(text)
    shown.foregroundColor = .clear
    var dimmed = AttributedString(hint)
    dimmed.foregroundColor = Color(nsColor: .tertiaryLabelColor)
    return shown + dimmed
  }
}

@MainActor
enum PromptTextStyle {
  static var font: NSFont { NSFont.systemFont(ofSize: NSFont.systemFontSize) }
  static let inset = NSSize(width: 4, height: 5)

  static var lineHeight: CGFloat {
    NSLayoutManager().defaultLineHeight(for: font)
  }

  static func height(forLines lines: Int) -> CGFloat {
    CGFloat(lines) * lineHeight + inset.height * 2
  }

  /// The height of the lines on screen, held between the minimum and the maximum: what the editor
  /// asks for, with the text view as it is laid out now.
  static func height(of textView: NSTextView, minimumLines: Int, maximumLines: Int) -> CGFloat? {
    guard let layoutManager = textView.layoutManager, let container = textView.textContainer
    else { return nil }
    layoutManager.ensureLayout(for: container)
    let used = layoutManager.usedRect(for: container).height
    let content = min(
      max(used, CGFloat(minimumLines) * lineHeight), CGFloat(maximumLines) * lineHeight)
    return (content + inset.height * 2).rounded(.up)
  }
}

/// A scroll view whose scroller never takes width from the text, whatever the system prefers. A
/// legacy scroller, shown once the text overflows, narrows the column: more lines wrap, the editor
/// grows until nothing overflows, the scroller goes, the lines unwrap, and it shrinks again — for
/// ever, on a Mac set to always show scroll bars.
private final class OverlayScrollView: NSScrollView {
  override var scrollerStyle: NSScroller.Style {
    get { .overlay }
    set { super.scrollerStyle = .overlay }
  }
}

private struct GrowingTextView: NSViewRepresentable {
  @Binding var text: String
  @Binding var height: CGFloat?
  let minimumLines: Int
  let maximumLines: Int
  let accessibilityLabel: String
  let highlightsPlaceholders: Bool
  /// SwiftUI's focus does not reach an AppKit text view: the caret is placed here instead, each
  /// time this turns true.
  let focusRequested: Bool
  let isEditable: Bool
  let onSubmit: (() -> Void)?
  let onCancel: (() -> Void)?
  let commands: ComposerCommands?
  /// The command inserted from the list, tinted as a token.
  let token: String?

  func makeCoordinator() -> Coordinator {
    Coordinator()
  }

  func makeNSView(context: Context) -> NSScrollView {
    let textView = SessionNotesEditor.makeTextView()
    // Written for an agent: nothing is corrected, and a pasted colour stays out.
    textView.isContinuousSpellCheckingEnabled = false
    textView.usesFindBar = false
    textView.font = PromptTextStyle.font
    textView.typingAttributes = [
      .font: PromptTextStyle.font, .foregroundColor: NSColor.textColor,
    ]
    textView.textContainerInset = PromptTextStyle.inset
    textView.delegate = context.coordinator
    textView.string = text
    textView.postsFrameChangedNotifications = true

    let scrollView = OverlayScrollView()
    scrollView.hasVerticalScroller = true
    scrollView.autohidesScrollers = true
    scrollView.drawsBackground = false
    scrollView.borderType = .noBorder
    scrollView.contentView.drawsBackground = false
    scrollView.documentView = textView

    let coordinator = context.coordinator
    coordinator.parent = self
    coordinator.textView = textView
    // A narrower column wraps more lines: the height follows the width as much as the text.
    coordinator.frameObserver = NotificationCenter.default.addObserver(
      forName: NSView.frameDidChangeNotification, object: textView, queue: .main
    ) { [weak coordinator] _ in
      MainActor.assumeIsolated { coordinator?.remeasure() }
    }
    coordinator.highlight()
    coordinator.remeasure()
    return scrollView
  }

  func updateNSView(_ scrollView: NSScrollView, context: Context) {
    let coordinator = context.coordinator
    coordinator.parent = self
    guard let textView = coordinator.textView else { return }
    if textView.string != text, !coordinator.isEditing {
      // The edits recorded for ⌘Z are placed in the text replaced: kept, the next ⌘Z would raise,
      // and the one after abort the application (see `ReplaceableTextEditor`).
      if let storage = textView.textStorage {
        textView.undoManager?.removeAllActions(withTarget: storage)
      }
      textView.string = text
      // Put in from elsewhere — a command chosen with a click — the text is carried on at its end.
      textView.setSelectedRange(NSRange(location: (text as NSString).length, length: 0))
      coordinator.highlight()
    } else if coordinator.shownToken != token {
      coordinator.highlight()
    }
    textView.setAccessibilityLabel(accessibilityLabel)
    textView.isEditable = isEditable
    coordinator.remeasure()
    if focusRequested, !coordinator.focusWasRequested {
      coordinator.takeFocus(attempts: 5)
    }
    coordinator.focusWasRequested = focusRequested
  }

  static func dismantleNSView(_ scrollView: NSScrollView, coordinator: Coordinator) {
    if let observer = coordinator.frameObserver {
      NotificationCenter.default.removeObserver(observer)
    }
  }

  @MainActor
  final class Coordinator: NSObject, NSTextViewDelegate {
    var parent: GrowingTextView?
    weak var textView: NSTextView?
    var frameObserver: (any NSObjectProtocol)?
    private(set) var isEditing = false
    var focusWasRequested = false
    /// The token tinted last.
    private(set) var shownToken: String?

    func takeFocus(attempts: Int) {
      DispatchQueue.main.async { [weak self] in
        guard let self, let textView = self.textView else { return }
        guard let window = textView.window else {
          if attempts > 0 { self.takeFocus(attempts: attempts - 1) }
          return
        }
        window.makeFirstResponder(textView)
      }
    }

    /// Return submits when the editor was given something to submit to. ⇧↩ and ⌥↩ still go to the
    /// line, and so does Return while an input method is composing: it confirms the characters.
    func textView(_ textView: NSTextView, doCommandBy selector: Selector) -> Bool {
      if handleCommandList(textView, selector) { return true }
      // Escape, which a text view otherwise keeps for completion, goes to `onCancel` when given.
      if selector == #selector(NSResponder.cancelOperation(_:))
        || selector == #selector(NSTextView.complete(_:)),
        let onCancel = parent?.onCancel, !textView.hasMarkedText()
      {
        onCancel()
        return true
      }
      guard selector == #selector(NSResponder.insertNewline(_:)), let onSubmit = parent?.onSubmit,
        !textView.hasMarkedText()
      else { return false }
      let modifiers = NSApp.currentEvent?.modifierFlags ?? []
      guard modifiers.isDisjoint(with: [.shift, .option]) else { return false }
      onSubmit()
      return true
    }

    /// While the list under `/` is open, ↑ and ↓ move in it, ⇥ and ↩ insert the entry selected —
    /// sending nothing — and Escape closes it. With nothing matching, ↩ submits as ever.
    private func handleCommandList(_ textView: NSTextView, _ selector: Selector) -> Bool {
      guard let commands = parent?.commands, commands.isShowing, !textView.hasMarkedText()
      else { return false }
      switch selector {
      case #selector(NSResponder.moveUp(_:)):
        return commands.moveSelection(by: -1)
      case #selector(NSResponder.moveDown(_:)):
        return commands.moveSelection(by: 1)
      case #selector(NSResponder.insertTab(_:)), #selector(NSResponder.insertNewline(_:)):
        guard let command = commands.selectedCommand else { return false }
        let modifiers = NSApp.currentEvent?.modifierFlags ?? []
        guard modifiers.isDisjoint(with: [.shift, .option]) else { return false }
        // Typed in, as the user would: ⌘Z takes it back.
        let whole = NSRange(location: 0, length: (textView.string as NSString).length)
        textView.insertText(commands.inserting(command), replacementRange: whole)
        return true
      case #selector(NSResponder.cancelOperation(_:)):
        return commands.dismiss()
      default:
        return false
      }
    }

    func textDidChange(_ notification: Notification) {
      guard let textView else { return }
      isEditing = true
      parent?.text = textView.string
      isEditing = false
      highlight()
      remeasure()
      textView.scrollRangeToVisible(textView.selectedRange())
    }

    /// Asks for the height of the lines on screen, when it changed.
    func remeasure() {
      guard let parent, let textView,
        let height = PromptTextStyle.height(
          of: textView, minimumLines: parent.minimumLines, maximumLines: parent.maximumLines)
      else { return }
      guard parent.height != height else { return }
      // Published after the pass that asked for it: SwiftUI must not be changed while it draws.
      DispatchQueue.main.async { [weak self] in
        guard let parent = self?.parent, parent.height != height else { return }
        parent.height = height
      }
    }

    /// Fields in a template's text are tinted, and double braces that are not a field underlined.
    /// Drawn as temporary attributes: nothing of it reaches the text itself.
    func highlight() {
      guard let parent, let textView, let layoutManager = textView.layoutManager else { return }
      let whole = NSRange(location: 0, length: (textView.string as NSString).length)
      tintToken(parent.token, in: textView, layoutManager: layoutManager, whole: whole)
      guard parent.highlightsPlaceholders else { return }
      layoutManager.removeTemporaryAttribute(.backgroundColor, forCharacterRange: whole)
      layoutManager.removeTemporaryAttribute(.underlineStyle, forCharacterRange: whole)
      layoutManager.removeTemporaryAttribute(.underlineColor, forCharacterRange: whole)
      let parsed = PromptTemplateSyntax.parse(textView.string)
      for placeholder in parsed.placeholders {
        layoutManager.addTemporaryAttribute(
          .backgroundColor,
          value: NSColor.controlAccentColor.withAlphaComponent(0.18),
          forCharacterRange: NSRange(placeholder.range))
      }
      for range in parsed.malformed {
        layoutManager.addTemporaryAttributes(
          [
            .underlineStyle: NSUnderlineStyle.single.rawValue
              | NSUnderlineStyle.patternDot.rawValue,
            .underlineColor: NSColor.secondaryLabelColor,
          ],
          forCharacterRange: NSRange(range))
      }
    }
  }
}

extension GrowingTextView.Coordinator {
  /// The command inserted from the list, at the head of the text, tinted as a token (#219).
  fileprivate func tintToken(
    _ token: String?, in textView: NSTextView, layoutManager: NSLayoutManager, whole: NSRange
  ) {
    guard token != nil || shownToken != nil else { return }
    if let shown = shownToken {
      let range = NSRange(location: 0, length: min((shown as NSString).length, whole.length))
      layoutManager.removeTemporaryAttribute(.backgroundColor, forCharacterRange: range)
    }
    shownToken = nil
    let text = textView.string as NSString
    guard let token, text.hasPrefix(token) else { return }
    layoutManager.addTemporaryAttribute(
      .backgroundColor, value: NSColor.controlAccentColor.withAlphaComponent(0.18),
      forCharacterRange: NSRange(location: 0, length: (token as NSString).length))
    shownToken = token
  }
}

extension NSRange {
  fileprivate init(_ range: Range<Int>) {
    self.init(location: range.lowerBound, length: range.count)
  }
}

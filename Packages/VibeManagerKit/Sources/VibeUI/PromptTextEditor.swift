import AppKit
import SwiftUI
import VibeDomain

/// Where a prompt is written: a plain-text area as tall as what it holds.
///
/// It grows with the lines on screen — wrapped lines included, not only the `\n` — from
/// `minimumLines` up to `maximumLines`, then scrolls inside, so a short prompt is read whole and a
/// long one does not push the rest of the form off the screen. Return goes to the line; the form
/// around it decides what ⌘↩ does.
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
  @State private var height: CGFloat?

  public init(
    text: Binding<String>,
    minimumLines: Int = 3,
    maximumLines: Int = PromptTextEditor.defaultMaximumLines,
    placeholder: String? = nil,
    accessibilityLabel: String,
    highlightsPlaceholders: Bool = false,
    focusRequested: Bool = false,
    isEditable: Bool = true
  ) {
    _text = text
    self.minimumLines = minimumLines
    self.maximumLines = maximumLines
    self.placeholder = placeholder
    self.accessibilityLabel = accessibilityLabel
    self.highlightsPlaceholders = highlightsPlaceholders
    self.focusRequested = focusRequested
    self.isEditable = isEditable
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
      isEditable: isEditable
    )
    .frame(height: height ?? PromptTextStyle.height(forLines: minimumLines))
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
    .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
    .overlay {
      RoundedRectangle(cornerRadius: 6).strokeBorder(.separator)
    }
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

    let scrollView = NSScrollView()
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
      textView.string = text
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

    func textDidChange(_ notification: Notification) {
      guard let textView else { return }
      isEditing = true
      parent?.text = textView.string
      isEditing = false
      highlight()
      remeasure()
      textView.scrollRangeToVisible(textView.selectedRange())
    }

    /// The height of the lines on screen, held between the minimum and the maximum.
    func remeasure() {
      guard let parent, let textView, let layoutManager = textView.layoutManager,
        let container = textView.textContainer
      else { return }
      layoutManager.ensureLayout(for: container)
      let lineHeight = PromptTextStyle.lineHeight
      let used = layoutManager.usedRect(for: container).height
      let content = min(
        max(used, CGFloat(parent.minimumLines) * lineHeight),
        CGFloat(parent.maximumLines) * lineHeight)
      let height = (content + PromptTextStyle.inset.height * 2).rounded(.up)
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
      guard let parent, parent.highlightsPlaceholders, let textView,
        let layoutManager = textView.layoutManager
      else { return }
      let whole = NSRange(location: 0, length: (textView.string as NSString).length)
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

extension NSRange {
  fileprivate init(_ range: Range<Int>) {
    self.init(location: range.lowerBound, length: range.count)
  }
}

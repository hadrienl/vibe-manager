import AppKit
import ObjectiveC
import SwiftUI
import UniformTypeIdentifiers

/// Lets the drags of files through the composer's text field, to the view behind it (#146).
///
/// A file dropped on the conversation becomes a chip of the composer: the session's column takes
/// the drop, over all of its surface (ADR 0028). But the text view SwiftUI draws the field with
/// is an `NSTextView`, and AppKit gives a drag to the frontmost view registered for it: the field
/// took a file first and typed its path. It keeps the drags of text, which it inserts where they
/// are let go; a drag that carries a file, an image or a promised file is handed, from its entry
/// to its end, to the view that would have taken it without the field — the session's zone, which
/// reads it as every other drop.
///
/// SwiftUI's `TextEditor` exposes neither its text view nor a way to choose what it accepts: the
/// text view it made is given a subclass of its own class, made at run time, that overrides the
/// methods of `NSDraggingDestination` and nothing else — as key-value observing does.
@MainActor
enum ComposerDropPassage {
  private static let prefix = "VibeComposerDropPassage_"

  /// The view each text view hands the drag in progress to.
  private static let targets = NSMapTable<NSView, NSView>.weakToWeakObjects()

  /// Gives `textView` the passage. Nothing happens to one that has it already, or whose class
  /// cannot be given a subclass — one already observed, for instance: it keeps AppKit's behaviour.
  static func install(on textView: NSTextView) {
    guard let original = object_getClass(textView) else { return }
    let name = String(cString: class_getName(original))
    guard !name.hasPrefix(prefix), !name.hasPrefix("NSKVONotifying_"),
      let subclass = subclass(of: original, named: prefix + name)
    else { return }
    object_setClass(textView, subclass)
  }

  static func isInstalled(on textView: NSTextView) -> Bool {
    guard let current = object_getClass(textView) else { return false }
    return String(cString: class_getName(current)).hasPrefix(prefix)
  }

  /// Whether a drag carries what the session's zone makes a chip of: a file of the disk — a
  /// folder, an image — an image with no file, or a file its source promises. A text, a web
  /// address or a selection of a page is left to the field.
  static func carriesFiles(_ pasteboard: NSPasteboard) -> Bool {
    let promises = Set(NSFilePromiseReceiver.readableDraggedTypes)
    return (pasteboard.types ?? []).contains { type in
      if type == .fileURL || type == NSPasteboard.PasteboardType("NSFilenamesPboardType")
        || promises.contains(type.rawValue)
      {
        return true
      }
      guard let uti = UTType(type.rawValue) else { return false }
      return uti.conforms(to: .image) || uti.conforms(to: .fileURL)
    }
  }

  /// The view that takes a drag let go at `location`, in the window's coordinates, when no text
  /// view is there: the frontmost view registered for drags under that point.
  static func destination(behind textView: NSView, at location: NSPoint) -> NSView? {
    guard let root = textView.window?.contentView else { return nil }
    return frontmost(in: root, at: location)
  }

  private static func frontmost(in view: NSView, at location: NSPoint) -> NSView? {
    // No text view, this one or another composer of the stack of conversations, which would pass
    // the drag on in turn.
    guard !view.isHidden, !(view is NSTextView),
      view.bounds.contains(view.convert(location, from: nil))
    else { return nil }
    for subview in view.subviews.reversed() {
      if let found = frontmost(in: subview, at: location) { return found }
    }
    return view.registeredDraggedTypes.isEmpty ? nil : view
  }

  // MARK: - The drag, from its entry to its end

  fileprivate static func entered(
    _ textView: NSTextView, _ drag: any NSDraggingInfo, otherwise: () -> NSDragOperation
  ) -> NSDragOperation {
    targets.removeObject(forKey: textView)
    guard carriesFiles(drag.draggingPasteboard),
      let target = destination(behind: textView, at: drag.draggingLocation)
    else { return otherwise() }
    targets.setObject(target, forKey: textView)
    return target.draggingEntered(drag)
  }

  fileprivate static func updated(
    _ textView: NSTextView, _ drag: any NSDraggingInfo, otherwise: () -> NSDragOperation
  ) -> NSDragOperation {
    guard let target = targets.object(forKey: textView) else {
      // Entered before the passage was given, or never announced: taken from here.
      guard carriesFiles(drag.draggingPasteboard) else { return otherwise() }
      return entered(textView, drag, otherwise: otherwise)
    }
    return target.draggingUpdated(drag)
  }

  fileprivate static func exited(
    _ textView: NSTextView, _ drag: (any NSDraggingInfo)?, otherwise: () -> Void
  ) {
    guard let target = targets.object(forKey: textView) else { return otherwise() }
    targets.removeObject(forKey: textView)
    target.draggingExited(drag)
  }

  fileprivate static func prepare(
    _ textView: NSTextView, _ drag: any NSDraggingInfo, otherwise: () -> Bool
  ) -> Bool {
    guard let target = targets.object(forKey: textView) else { return otherwise() }
    return target.prepareForDragOperation(drag)
  }

  fileprivate static func perform(
    _ textView: NSTextView, _ drag: any NSDraggingInfo, otherwise: () -> Bool
  ) -> Bool {
    guard let target = targets.object(forKey: textView) else { return otherwise() }
    return target.performDragOperation(drag)
  }

  fileprivate static func conclude(
    _ textView: NSTextView, _ drag: (any NSDraggingInfo)?, otherwise: () -> Void
  ) {
    guard let target = targets.object(forKey: textView) else { return otherwise() }
    targets.removeObject(forKey: textView)
    target.concludeDragOperation(drag)
  }

  fileprivate static func ended(_ textView: NSTextView, _ drag: any NSDraggingInfo) {
    guard let target = targets.object(forKey: textView) else { return }
    targets.removeObject(forKey: textView)
    target.draggingEnded(drag)
  }

  // MARK: - The subclass

  private typealias Operation =
    @convention(c) (NSObject, Selector, any NSDraggingInfo) ->
    NSDragOperation
  private typealias Decision = @convention(c) (NSObject, Selector, any NSDraggingInfo) -> Bool
  private typealias Notice = @convention(c) (NSObject, Selector, (any NSDraggingInfo)?) -> Void
  private typealias Ending = @convention(c) (NSObject, Selector, any NSDraggingInfo) -> Void

  private static func subclass(of original: AnyClass, named name: String) -> AnyClass? {
    if let existing = objc_lookUpClass(name) { return existing }
    guard let subclass = objc_allocateClassPair(original, name, 0) else { return nil }
    for (selector, block) in overrides(of: original) {
      guard let method = class_getInstanceMethod(original, selector),
        class_addMethod(
          subclass, selector, imp_implementationWithBlock(block), method_getTypeEncoding(method))
      else {
        objc_disposeClassPair(subclass)
        return nil
      }
    }
    objc_registerClassPair(subclass)
    return subclass
  }

  /// Each method of `NSDraggingDestination` the text view implements, and what replaces it: the
  /// passage, falling back on the original class's own method — its `super`.
  private static func overrides(of original: AnyClass) -> [(Selector, Any)] {
    func inherited<Function>(_ selector: Selector, as _: Function.Type) -> Function {
      unsafeBitCast(class_getMethodImplementation(original, selector), to: Function.self)
    }
    let enteredSelector = #selector(NSDraggingDestination.draggingEntered(_:))
    let updatedSelector = #selector(NSDraggingDestination.draggingUpdated(_:))
    let exitedSelector = #selector(NSDraggingDestination.draggingExited(_:))
    let prepareSelector = #selector(NSDraggingDestination.prepareForDragOperation(_:))
    let performSelector = #selector(NSDraggingDestination.performDragOperation(_:))
    let concludeSelector = #selector(NSDraggingDestination.concludeDragOperation(_:))
    let endedSelector = #selector(NSDraggingDestination.draggingEnded(_:))

    let superEntered = inherited(enteredSelector, as: Operation.self)
    let superUpdated = inherited(updatedSelector, as: Operation.self)
    let superExited = inherited(exitedSelector, as: Notice.self)
    let superPrepare = inherited(prepareSelector, as: Decision.self)
    let superPerform = inherited(performSelector, as: Decision.self)
    let superConclude = inherited(concludeSelector, as: Notice.self)
    let superEnded = inherited(endedSelector, as: Ending.self)

    let entered: @convention(block) (NSTextView, any NSDraggingInfo) -> NSDragOperation = {
      view, drag in
      MainActor.assumeIsolated {
        Self.entered(view, drag) { superEntered(view, enteredSelector, drag) }
      }
    }
    let updated: @convention(block) (NSTextView, any NSDraggingInfo) -> NSDragOperation = {
      view, drag in
      MainActor.assumeIsolated {
        Self.updated(view, drag) { superUpdated(view, updatedSelector, drag) }
      }
    }
    let exited: @convention(block) (NSTextView, (any NSDraggingInfo)?) -> Void = { view, drag in
      MainActor.assumeIsolated {
        Self.exited(view, drag) { superExited(view, exitedSelector, drag) }
      }
    }
    let prepare: @convention(block) (NSTextView, any NSDraggingInfo) -> Bool = { view, drag in
      MainActor.assumeIsolated {
        Self.prepare(view, drag) { superPrepare(view, prepareSelector, drag) }
      }
    }
    let perform: @convention(block) (NSTextView, any NSDraggingInfo) -> Bool = { view, drag in
      MainActor.assumeIsolated {
        Self.perform(view, drag) { superPerform(view, performSelector, drag) }
      }
    }
    let conclude: @convention(block) (NSTextView, (any NSDraggingInfo)?) -> Void = {
      view, drag in
      MainActor.assumeIsolated {
        Self.conclude(view, drag) { superConclude(view, concludeSelector, drag) }
      }
    }
    let ended: @convention(block) (NSTextView, any NSDraggingInfo) -> Void = { view, drag in
      MainActor.assumeIsolated {
        Self.ended(view, drag)
        // The text view ends what it began, if it began anything: its own drop caret.
        superEnded(view, endedSelector, drag)
      }
    }
    return [
      (enteredSelector, entered), (updatedSelector, updated), (exitedSelector, exited),
      (prepareSelector, prepare), (performSelector, perform), (concludeSelector, conclude),
      (endedSelector, ended),
    ]
  }
}

/// Placed behind the composer's `TextEditor`, finds the text view SwiftUI made for it and gives
/// it the passage — again whenever the composer is drawn anew, SwiftUI being free to make another.
struct ComposerDropPassageAnchor: NSViewRepresentable {
  func makeNSView(context: Context) -> AnchorView { AnchorView() }

  func updateNSView(_ view: AnchorView, context: Context) {
    view.scheduleInstall()
  }

  final class AnchorView: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func viewDidMoveToWindow() {
      super.viewDidMoveToWindow()
      scheduleInstall()
    }

    override func layout() {
      super.layout()
      scheduleInstall()
    }

    /// Once SwiftUI has put the text editor in place and laid it out, next to this view — which
    /// it may do some turns of the run loop after this view: looked for again a few times.
    func scheduleInstall() {
      install(attempts: 20, after: .milliseconds(0))
    }

    private func install(attempts: Int, after delay: DispatchTimeInterval) {
      DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
        MainActor.assumeIsolated {
          guard let self, self.window != nil, !self.install(), attempts > 1 else { return }
          self.install(attempts: attempts - 1, after: .milliseconds(50))
        }
      }
    }

    /// SwiftUI hosts this view and the text editor side by side, the background first, each
    /// wrapped in views of its own: the text view is in the first of the views drawn after one
    /// of this view's ancestors that lies where this view lies.
    /// Whether the text view was found.
    private func install() -> Bool {
      guard let root = window?.contentView else { return false }
      let frame = convert(bounds, to: nil)
      var child: NSView = self
      while child !== root, let parent = child.superview,
        let index = parent.subviews.firstIndex(of: child)
      {
        for sibling in parent.subviews[(index + 1)...]
        where sibling.convert(sibling.bounds, to: nil).intersects(frame) {
          if let textView = Self.textView(in: sibling) {
            ComposerDropPassage.install(on: textView)
            return true
          }
        }
        child = parent
      }
      return false
    }

    private static func textView(in view: NSView) -> NSTextView? {
      if let textView = view as? NSTextView { return textView }
      return view.subviews.lazy.compactMap(textView(in:)).first
    }
  }
}

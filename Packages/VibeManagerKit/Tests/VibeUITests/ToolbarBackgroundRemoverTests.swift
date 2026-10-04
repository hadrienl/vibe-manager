import AppKit
import Testing

@testable import VibeUI

/// The toolbar backgrounds AppKit draws under the toolbar (#317). The views are AppKit's own, in a
/// hierarchy never put on screen.
@MainActor
@Suite("The toolbar backgrounds are hidden, and stay hidden")
struct ToolbarBackgroundRemoverTests {
  private func background() throws -> NSView {
    let type = try #require(
      NSClassFromString(ToolbarBackgroundRemover.backgroundClassName) as? NSView.Type)
    return type.init(frame: NSRect(x: 280, y: 0, width: 1774, height: 91))
  }

  /// A frame holding the columns' split view, the inspector's one inside it with a background,
  /// a background in the columns' one, and one in the title bar.
  private func hierarchy() throws -> (root: NSView, backgrounds: [NSView]) {
    let root = NSView()
    let columns = NSSplitView()
    let detail = NSView()
    let inspector = NSSplitView()
    let inInspector = try background()
    let inColumns = try background()
    let inTitlebar = try background()
    inspector.addSubview(inInspector)
    detail.addSubview(inspector)
    columns.addSubview(detail)
    columns.addSubview(inColumns)
    root.addSubview(columns)
    root.addSubview(inTitlebar)
    return (root, [inColumns, inTitlebar, inInspector])
  }

  @Test("Every background is found, nested split views included")
  func found() throws {
    let (root, backgrounds) = try hierarchy()
    #expect(Set(ToolbarBackgroundRemover.backgrounds(in: root)) == Set(backgrounds))
  }

  @Test("What scrolls is not walked")
  func scrollViewNotWalked() throws {
    let root = NSView()
    let scroll = NSScrollView()
    scroll.addSubview(try background())
    root.addSubview(scroll)
    #expect(ToolbarBackgroundRemover.backgrounds(in: root).isEmpty)
  }

  @Test("They are hidden, in every window looked at")
  func hidden() throws {
    let (root, backgrounds) = try hierarchy()
    let toolbarWindowRoot = NSView()
    let inToolbarWindow = try background()
    toolbarWindowRoot.addSubview(inToolbarWindow)
    let remover = ToolbarBackgroundRemover()
    remover.update(roots: [root, toolbarWindowRoot])
    let allHidden = (backgrounds + [inToolbarWindow]).allSatisfy { $0.isHidden }
    #expect(allHidden)
  }

  @Test("Shown again by AppKit, one is hidden at once")
  func hiddenAgainAtOnce() throws {
    let (root, backgrounds) = try hierarchy()
    let remover = ToolbarBackgroundRemover()
    remover.update(roots: [root])
    backgrounds[0].isHidden = false
    #expect(backgrounds[0].isHidden)
    // Moved to another window, as in full screen, it is still watched.
    let elsewhere = NSView()
    elsewhere.addSubview(backgrounds[2])
    backgrounds[2].isHidden = false
    #expect(backgrounds[2].isHidden)
  }

  @Test("Stopped, it shows them and lets them be")
  func stopped() throws {
    let (root, backgrounds) = try hierarchy()
    let remover = ToolbarBackgroundRemover()
    remover.update(roots: [root])
    remover.update(roots: [root])
    remover.stop()
    let allShown = backgrounds.allSatisfy { !$0.isHidden }
    #expect(allShown)
    backgrounds[0].isHidden = true
    backgrounds[0].isHidden = false
    #expect(!backgrounds[0].isHidden)
  }
}

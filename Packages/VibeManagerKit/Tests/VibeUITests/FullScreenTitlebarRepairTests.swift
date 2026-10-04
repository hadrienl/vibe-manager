import AppKit
import Testing

@testable import VibeUI

/// The toolbar background AppKit leaves in the split view of a full-screen window (#317). The
/// views are AppKit's own, in a hierarchy never put on screen: full screen itself cannot be
/// entered by a test, so the repair is told whether the window is in it.
@MainActor
@Suite("A toolbar background left in a full-screen split view is hidden")
struct FullScreenTitlebarRepairTests {
  private func background() throws -> NSView {
    let type = try #require(
      NSClassFromString(FullScreenTitlebarRepair.backgroundClassName) as? NSView.Type)
    return type.init(frame: NSRect(x: 280, y: 0, width: 1774, height: 91))
  }

  /// A frame holding a split view, the background among its columns, and another one elsewhere.
  private func hierarchy() throws -> (root: NSView, stray: NSView, elsewhere: NSView) {
    let root = NSView()
    let content = NSView()
    let split = NSSplitView()
    let stray = try background()
    let elsewhere = try background()
    split.addSubview(NSView())
    split.addSubview(stray)
    content.addSubview(split)
    root.addSubview(content)
    root.addSubview(elsewhere)
    return (root, stray, elsewhere)
  }

  @Test("Only the backgrounds held by a split view are found")
  func found() throws {
    let (root, stray, _) = try hierarchy()
    #expect(FullScreenTitlebarRepair.strayBackgrounds(in: root) == [stray])
  }

  @Test("In full screen it is hidden; out of it, shown again")
  func hiddenWhileFullScreen() throws {
    let (root, stray, elsewhere) = try hierarchy()
    let repair = FullScreenTitlebarRepair()
    repair.update(root: root, isFullScreen: false)
    #expect(!stray.isHidden)
    repair.update(root: root, isFullScreen: true)
    #expect(stray.isHidden)
    #expect(!elsewhere.isHidden)
    repair.update(root: root, isFullScreen: false)
    #expect(!stray.isHidden)
  }

  @Test("Taken back out of the split view, it is shown there")
  func shownWhereItBelongs() throws {
    let (root, stray, elsewhere) = try hierarchy()
    let repair = FullScreenTitlebarRepair()
    repair.update(root: root, isFullScreen: true)
    #expect(stray.isHidden)
    stray.removeFromSuperview()
    elsewhere.superview?.addSubview(stray)
    repair.update(root: root, isFullScreen: true)
    #expect(!stray.isHidden)
  }

  @Test("A background the app hid itself is left as it is")
  func alreadyHidden() throws {
    let (root, stray, _) = try hierarchy()
    stray.isHidden = true
    let repair = FullScreenTitlebarRepair()
    repair.update(root: root, isFullScreen: true)
    repair.update(root: root, isFullScreen: false)
    #expect(stray.isHidden)
  }

  @Test("In the inspector's split view, inside the columns' one, it is found too")
  func foundInNestedSplitView() throws {
    let root = NSView()
    let columns = NSSplitView()
    let detail = NSView()
    let inspector = NSSplitView()
    let stray = try background()
    inspector.addSubview(stray)
    detail.addSubview(inspector)
    columns.addSubview(detail)
    root.addSubview(columns)
    #expect(FullScreenTitlebarRepair.strayBackgrounds(in: root) == [stray])
  }

  @Test("What scrolls is not walked")
  func scrollViewNotWalked() throws {
    let root = NSView()
    let scroll = NSScrollView()
    let split = NSSplitView()
    split.addSubview(try background())
    scroll.addSubview(split)
    root.addSubview(scroll)
    #expect(FullScreenTitlebarRepair.strayBackgrounds(in: root).isEmpty)
  }

  @Test("Shown again by AppKit while in full screen, it is hidden at once")
  func hiddenAgainAtOnce() throws {
    let (root, stray, _) = try hierarchy()
    let repair = FullScreenTitlebarRepair()
    repair.update(root: root, isFullScreen: true)
    stray.isHidden = false
    #expect(stray.isHidden)
    repair.update(root: root, isFullScreen: true)
    #expect(stray.isHidden)
    // Tracked once: out of full screen, shown, and left shown.
    repair.update(root: root, isFullScreen: false)
    #expect(!stray.isHidden)
    stray.isHidden = true
    stray.isHidden = false
    #expect(!stray.isHidden)
  }

  @Test("Stopped, it shows what it hid")
  func stopped() throws {
    let (root, stray, _) = try hierarchy()
    let repair = FullScreenTitlebarRepair()
    repair.update(root: root, isFullScreen: true)
    #expect(stray.isHidden)
    repair.stop()
    #expect(!stray.isHidden)
    stray.isHidden = false
    #expect(!stray.isHidden)
  }
}

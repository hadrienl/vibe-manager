import AppKit
import Testing

@testable import VibeBrowser

@Suite("The window parked pages wait in")
@MainActor
struct ParkingWindowTests {
  init() {
    _ = NSApplication.shared
  }

  @Test("goes back off every screen when something moves it onto one")
  func returnsWhenMoved() {
    let window = ParkingWindow()
    defer { window.orderOut(nil) }
    window.setFrameOrigin(NSPoint(x: 100, y: 100))
    #expect(window.frame == ParkingWindow.parkedFrame)
  }

  @Test("goes back off every screen when the displays change")
  func returnsWhenScreensChange() {
    let window = ParkingWindow()
    defer { window.orderOut(nil) }
    window.setFrameOrigin(NSPoint(x: 100, y: 100))
    NotificationCenter.default.post(
      name: NSApplication.didChangeScreenParametersNotification, object: NSApp)
    #expect(window.frame.origin == ParkingWindow.parkedFrame.origin)
  }

  @Test("is never constrained onto a screen")
  func isNotConstrained() {
    let window = ParkingWindow()
    #expect(
      window.constrainFrameRect(ParkingWindow.parkedFrame, to: NSScreen.main)
        == ParkingWindow.parkedFrame)
  }
}

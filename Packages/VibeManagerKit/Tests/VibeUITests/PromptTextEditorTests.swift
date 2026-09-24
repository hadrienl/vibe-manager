import AppKit
import SwiftUI
import Testing

@testable import VibeUI

@MainActor
@Suite("A prompt area that grows with its text", .timeLimit(.minutes(1)))
struct PromptTextEditorTests {
  /// Hosts the editor in a window that is never shown, and returns its height once laid out.
  private func height(of text: String, width: CGFloat = 400, minimumLines: Int = 3) async
    -> CGFloat
  {
    let host = NSHostingView(
      rootView: Host(text: text, minimumLines: minimumLines).frame(width: width))
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: width, height: 800),
      styleMask: [.borderless], backing: .buffered, defer: false)
    // Owned by this test, not by AppKit: a window made in code releases itself when closed.
    window.isReleasedWhenClosed = false
    window.contentView = host
    defer {
      window.contentView = nil
      window.close()
    }
    // The height is published after the layout pass that measured it, so it is read once it has
    // stopped moving — with no deadline of its own, which a busy runner outlasts: the suite's time
    // limit stops a height that never settles.
    var height = host.fittingSize.height
    var stableRounds = 0
    while stableRounds < 3 {
      host.layoutSubtreeIfNeeded()
      try? await Task.sleep(for: .milliseconds(20))
      let next = host.fittingSize.height
      stableRounds = next == height ? stableRounds + 1 : 0
      height = next
    }
    return height
  }

  private struct Host: View {
    @State var text: String
    let minimumLines: Int

    var body: some View {
      PromptTextEditor(text: $text, minimumLines: minimumLines, accessibilityLabel: "Prompt")
    }
  }

  private var line: CGFloat { PromptTextStyle.lineHeight }

  @Test("Empty, it keeps its minimum")
  func emptyKeepsMinimum() async {
    let height = await height(of: "")
    #expect(abs(height - PromptTextStyle.height(forLines: 3)) <= 1)
  }

  @Test("It grows line by line, then stops at ten lines")
  func growsThenStops() async {
    let five = await height(of: (1...5).map { "line \($0)" }.joined(separator: "\n"))
    let thirty = await height(of: (1...30).map { "line \($0)" }.joined(separator: "\n"))
    #expect(abs(five - PromptTextStyle.height(forLines: 5)) <= 2)
    #expect(abs(thirty - PromptTextStyle.height(forLines: 10)) <= 2)
  }

  @Test("A line that wraps counts as the lines it takes on screen")
  func wrappedLinesCount() async {
    let long = String(repeating: "word ", count: 60)
    let wide = await height(of: long, width: 900, minimumLines: 1)
    let narrow = await height(of: long, width: 250, minimumLines: 1)
    #expect(narrow > wide + line)
  }
}

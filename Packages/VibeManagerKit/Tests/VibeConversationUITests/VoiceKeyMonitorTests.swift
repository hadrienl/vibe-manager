import AppKit
import Testing

@testable import VibeConversationUI

@Suite("Where Space is the microphone's (#357)")
@MainActor
struct VoiceKeyMonitorTests {
  @Test("A field being written, a focused button or list keep Space; the conversation does not")
  func whereSpaceIsUsed() {
    let editable = NSTextView()
    #expect(VoiceKeyMonitor.usesSpace(editable))
    let readOnly = NSTextView()
    readOnly.isEditable = false
    #expect(!VoiceKeyMonitor.usesSpace(readOnly))
    #expect(VoiceKeyMonitor.usesSpace(NSButton()))
    #expect(VoiceKeyMonitor.usesSpace(NSOutlineView()))
    #expect(!VoiceKeyMonitor.usesSpace(NSView()))
    #expect(!VoiceKeyMonitor.usesSpace(nil))
  }
}

import AppKit
import SwiftUI
import Testing
import VibeApplication
import VibeDomain

@testable import VibeConversationUI

/// The filters over the overview (#572): six buttons on one row, or, narrower than that, one
/// that opens a menu of the kinds — never two rows.
@MainActor
@Suite("The overview's filters, wide and narrow")
struct OverviewFilterBarTests {
  /// Two commits and an error: moments of two kinds.
  private static func model() -> ConversationModel {
    func shell(_ id: String, _ command: String) -> ConversationEntry {
      ConversationEntry(
        id: id,
        content: .tool(
          ToolCall(
            callID: id, kind: .shell, state: .succeeded, parameters: [.init(.command, command)])))
    }
    let model = ConversationModel(sessionID: SessionID())
    let entries = [
      ConversationEntry(id: "m0", content: .userPrompt("Commit", attachments: [])),
      shell("m1", "git commit -m one"),
      ConversationEntry(id: "m2", content: .notice(.error("Overloaded"))),
      shell("m3", "git push origin main"),
    ]
    model.apply(ConversationSnapshot(entries: entries, availability: .available))
    return model
  }

  private static func appearance(hiding kinds: Set<String> = []) -> ConversationAppearance {
    var appearance = ConversationAppearance()
    appearance.hiddenMomentKinds = kinds
    return appearance
  }

  @Test("Each kind says how many moments it has")
  func counts() {
    // Count the supplied moments, independently of transcript command recognition.
    let moments: [ConversationMoments.Placed] = [
      .init(blockIndex: 0, moment: .init(.commit(subject: "one"), entryID: "m1", date: nil)),
      .init(blockIndex: 1, moment: .init(.error("Overloaded"), entryID: "m2", date: nil)),
      .init(blockIndex: 2, moment: .init(.push(branch: "main"), entryID: "m3", date: nil)),
    ]
    let filters = OverviewFilters(moments: moments, appearance: Self.appearance())
    #expect(filters.count(of: .git) == 2)
    #expect(filters.count(of: .incident) == 1)
    #expect(filters.count(of: .tests) == 0)
  }

  @Test("The menu's button says how many kinds are shown, only when some are hidden")
  func counter() {
    let model = Self.model()
    let all = OverviewFilters(moments: model.moments, appearance: Self.appearance())
    #expect(all.showsAll)
    #expect(all.badge == nil)
    #expect(all.accessibilityValue == "6 of 6")

    let some = OverviewFilters(
      moments: model.moments, appearance: Self.appearance(hiding: ["tests"]))
    #expect(!some.showsAll)
    #expect(some.shownCount == 5)
    #expect(some.badge == "5/6")
    #expect(some.accessibilityValue == "5 of 6")
  }

  @Test("A line of the menu turns its kind over, as its button does")
  func toggleFromTheMenu() {
    let model = Self.model()
    var asked: [(ConversationMomentKind, Bool)] = []
    model.setMomentKindShown = { asked.append(($0, $1)) }
    OverviewFilters(moments: model.moments, appearance: Self.appearance()).toggle(.git, in: model)
    OverviewFilters(moments: model.moments, appearance: Self.appearance(hiding: ["incident"]))
      .toggle(.incident, in: model)
    #expect(asked.map(\.0) == [.git, .incident])
    #expect(asked.map(\.1) == [false, true])
  }

  @Test("Show All shows every kind hidden, and only those")
  func showAll() {
    let model = Self.model()
    var asked: [(ConversationMomentKind, Bool)] = []
    model.setMomentKindShown = { asked.append(($0, $1)) }
    OverviewFilters(
      moments: model.moments, appearance: Self.appearance(hiding: ["git", "question"])
    )
    .showAll(in: model)
    #expect(asked.map(\.0) == [.git, .question])
    #expect(asked.map(\.1) == [true, true])

    asked = []
    OverviewFilters(moments: model.moments, appearance: Self.appearance()).showAll(in: model)
    #expect(asked.isEmpty)
  }

  @Test("Native menu keeps each coloured icon, checkmark and count, including hidden kinds")
  func nativeMenu() throws {
    // AppKit dispatches menu actions through the application, also in a command-line test host.
    _ = NSApplication.shared
    let model = Self.model()
    var asked: [(ConversationMomentKind, Bool)] = []
    model.setMomentKindShown = { asked.append(($0, $1)) }
    let filters = OverviewFilters(
      moments: model.moments, appearance: Self.appearance(hiding: ["git"]))
    let menu = OverviewFilterMenu.makeMenu(model: model, filters: filters, theme: .systemDark)
    #expect(menu.items.count == OverviewFilters.kinds.count + 2)
    for (kind, item) in zip(OverviewFilters.kinds, menu.items) {
      #expect(item.title == MomentPresentation.name(of: kind))
      #expect(item.state == (kind == .git ? .off : .on))
      #expect(item.badge?.itemCount == filters.count(of: kind))
      #expect(item.badge?.stringValue == String(filters.count(of: kind)))
      let image = try #require(item.image)
      #expect(!image.isTemplate)
      #expect(image.size.width > 0 && image.size.height > 0)
      let data = try #require(image.tiffRepresentation)
      let bitmap = try #require(NSBitmapImageRep(data: data))
      let hasColour = (0..<bitmap.pixelsWide).contains { x in
        (0..<bitmap.pixelsHigh).contains { y in
          guard let colour = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else {
            return false
          }
          return colour.alphaComponent > 0.5
            && max(colour.redComponent, colour.greenComponent, colour.blueComponent)
              - min(colour.redComponent, colour.greenComponent, colour.blueComponent) > 0.1
        }
      }
      #expect(hasColour)
    }
    let gitIndex = try #require(OverviewFilters.kinds.firstIndex(of: .git))
    menu.performActionForItem(at: gitIndex)
    #expect(asked.map(\.0) == [.git])
    #expect(asked.map(\.1) == [true])
    #expect(menu.items[OverviewFilters.kinds.count].isSeparatorItem)
    #expect(menu.items.last?.isEnabled == true)
    let all = OverviewFilterMenu.makeMenu(
      model: model,
      filters: OverviewFilters(moments: model.moments, appearance: Self.appearance()),
      theme: .systemDark)
    #expect(all.items.last?.isEnabled == false)
  }

  // MARK: Width

  /// The form the bar takes at that width.
  private func form(atWidth width: Double) -> OverviewFilterBar.Form? {
    var form: OverviewFilterBar.Form?
    let hosting = NSHostingView(
      rootView: OverviewFilterBar(model: Self.model())
        .frame(width: width)
        .environment(\.conversationTheme, .systemDark)
        .environment(\.conversationAppearance, Self.appearance(hiding: ["tests"]))
        .onPreferenceChange(OverviewFilterBar.Form.Key.self) { form = $0 })
    hosting.frame = NSRect(x: 0, y: 0, width: width, height: 60)
    hosting.layoutSubtreeIfNeeded()
    return form
  }

  @Test("Wide enough, the six buttons on one row; narrower, the menu alone")
  func rowOrMenu() {
    #expect(form(atWidth: 140) == .row)
    #expect(form(atWidth: ConversationOverviewLayout.minimumWidth) == .menu)
  }

  @Test("The threshold is the row's own width: six buttons and their insets")
  func threshold() {
    let row =
      6 * OverviewFilterBar.buttonSize + 5 * OverviewFilterBar.spacing + 2
      * OverviewFilterBar.inset
    #expect(form(atWidth: row) == .row)
    #expect(form(atWidth: row - 1) == .menu)
  }
}

import AppKit
import SwiftUI
import VibeApplication

/// Over the overview, a button for each kind of moment, which shows or hides them (#572): in the
/// overview and in the margin of the messages, in every session. On, a button takes its kind's
/// colour; off, it is grey.
///
/// Never on two rows: narrower than the six buttons, a single one opens a menu of the kinds, each
/// checked when it is shown.
struct OverviewFilterBar: View {
  let model: ConversationModel
  @Environment(\.conversationTheme) private var theme
  @Environment(\.conversationAppearance) private var appearance

  static let buttonSize = 18.0
  static let spacing = 1.0
  /// Kept on each side of the row: below that, the menu.
  static let inset = 3.0

  var body: some View {
    let filters = OverviewFilters(moments: model.moments, appearance: appearance)
    // The bar's own width decides: the row while it holds on one line.
    ViewThatFits(in: .horizontal) {
      HStack(spacing: Self.spacing) {
        ForEach(OverviewFilters.kinds, id: \.self) { kind in
          button(kind, filters: filters)
        }
      }
      .padding(.horizontal, Self.inset)
      .preference(key: Form.Key.self, value: .row)
      OverviewFilterMenu(model: model, filters: filters)
        .preference(key: Form.Key.self, value: .menu)
    }
    .padding(.vertical, 5)
    .frame(maxWidth: .infinity)
    .overlay(alignment: .bottom) {
      Rectangle().fill(theme.border.color.opacity(0.6)).frame(height: 1)
    }
    .overlay(alignment: .leading) {
      Rectangle().fill(theme.border.color.opacity(0.6)).frame(width: 1)
    }
  }

  /// The form the bar took at its width, told above it: tests read it.
  enum Form: Equatable {
    case row
    case menu

    struct Key: PreferenceKey {
      static let defaultValue: Form? = nil
      static func reduce(value: inout Form?, nextValue: () -> Form?) {
        value = value ?? nextValue()
      }
    }
  }

  private func button(_ kind: ConversationMomentKind, filters: OverviewFilters) -> some View {
    let isShown = filters.shows(kind)
    let name = MomentPresentation.name(of: kind)
    let state =
      isShown
      ? String(localized: "\(filters.count(of: kind)) moments", bundle: .module)
      : String(localized: "Hidden", bundle: .module)
    return Button {
      filters.toggle(kind, in: model)
    } label: {
      MomentIcon(
        symbol: MomentPresentation.symbol(of: kind),
        color: isShown
          ? MomentPresentation.color(of: kind, theme: theme)
          : theme.secondaryText.color.opacity(0.55),
        size: 11
      )
      .frame(width: Self.buttonSize, height: Self.buttonSize)
      .background(
        isShown ? theme.text.color.opacity(0.07) : .clear,
        in: RoundedRectangle(cornerRadius: 4)
      )
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .help(Text(verbatim: "\(name) · \(state)"))
    .accessibilityLabel(Text(verbatim: name))
    .accessibilityValue(Text(verbatim: state))
    .accessibilityAddTraits(isShown ? .isSelected : [])
    .accessibilityIdentifier("moment-filter-\(kind.rawValue)")
  }
}

/// What the filters show, read once for the row and for the menu: how many moments of each kind
/// there are, and which kinds are shown.
struct OverviewFilters {
  static let kinds = ConversationMomentKind.allCases

  private let counts: [ConversationMomentKind: Int]
  private let appearance: ConversationAppearance

  init(moments: [ConversationMoments.Placed], appearance: ConversationAppearance) {
    counts = Dictionary(grouping: moments, by: \.moment.kind).mapValues(\.count)
    self.appearance = appearance
  }

  func count(of kind: ConversationMomentKind) -> Int { counts[kind] ?? 0 }
  func shows(_ kind: ConversationMomentKind) -> Bool { appearance.shows(kind) }

  var shownCount: Int { Self.kinds.count(where: shows) }
  var showsAll: Bool { shownCount == Self.kinds.count }

  /// Beside the menu's icon: "5/6" while a kind is hidden, nothing when all are shown.
  var badge: String? { showsAll ? nil : "\(shownCount)/\(Self.kinds.count)" }

  /// What VoiceOver reads of the menu: "5 of 6".
  var accessibilityValue: String {
    String(localized: "\(shownCount) of \(Self.kinds.count)", bundle: .module)
  }

  /// A kind shown hidden, or hidden shown: in every session, through the workspace.
  @MainActor func toggle(_ kind: ConversationMomentKind, in model: ConversationModel) {
    model.setMomentKindShown?(kind, !shows(kind))
  }

  /// Every kind hidden shown again.
  @MainActor func showAll(in model: ConversationModel) {
    for kind in Self.kinds where !shows(kind) {
      model.setMomentKindShown?(kind, true)
    }
  }
}

/// The filters when the overview is too narrow for their row (#572): one button, the number of
/// kinds shown beside its icon when some are hidden, which opens the menu of the kinds.
struct OverviewFilterMenu: View {
  let model: ConversationModel
  let filters: OverviewFilters
  @Environment(\.conversationTheme) private var theme

  @State private var anchor = NSView()

  var body: some View {
    let title = Text("Moment kinds shown", bundle: .module, comment: "The overview's filter menu.")
    Button {
      let menu = Self.makeMenu(model: model, filters: filters, theme: theme)
      menu.popUp(positioning: nil, at: NSPoint(x: 0, y: anchor.bounds.minY), in: anchor)
    } label: {
      HStack(spacing: 3) {
        Image(systemName: "line.3.horizontal.decrease")
          .font(.system(size: 10, weight: .semibold))
        if let badge = filters.badge {
          Text(verbatim: badge)
            .font(.system(size: 10, weight: .semibold))
            .monospacedDigit()
        }
        Image(systemName: "chevron.down")
          .font(.system(size: 7, weight: .bold))
      }
      .foregroundStyle(theme.secondaryText.color)
      .padding(.horizontal, 5)
      .frame(height: OverviewFilterBar.buttonSize)
      .background(theme.text.color.opacity(0.07), in: RoundedRectangle(cornerRadius: 4))
      .contentShape(Rectangle())
    }
    .background(MenuAnchor(view: anchor))
    .buttonStyle(.plain)
    .fixedSize()
    .instantTooltip(title)
    .accessibilityLabel(title)
    .accessibilityValue(Text(verbatim: filters.accessibilityValue))
    .accessibilityIdentifier("moment-filter-menu")
  }

  /// AppKit owns the rows: SwiftUI's Toggle menu bridge can discard a Label's image.
  static func makeMenu(
    model: ConversationModel, filters: OverviewFilters, theme: ConversationTheme
  ) -> NSMenu {
    let menu = NSMenu()
    menu.autoenablesItems = false
    for kind in OverviewFilters.kinds {
      let item = ClosureMenuItem(title: MomentPresentation.name(of: kind)) {
        filters.toggle(kind, in: model)
      }
      item.image = MomentMenuIcon.image(of: kind, theme: theme)
      item.state = filters.shows(kind) ? .on : .off
      let count = filters.count(of: kind)
      // AppKit suppresses a numeric zero badge; every kind still needs its count.
      item.badge = count == 0 ? NSMenuItemBadge(string: "0") : NSMenuItemBadge(count: count)
      menu.addItem(item)
    }
    menu.addItem(.separator())
    let all = ClosureMenuItem(
      title: String(localized: "Show All", bundle: .module)
    ) {
      filters.showAll(in: model)
    }
    all.isEnabled = !filters.showsAll
    menu.addItem(all)
    return menu
  }

  private struct MenuAnchor: NSViewRepresentable {
    let view: NSView
    func makeNSView(context: Context) -> NSView { view }
    func updateNSView(_ nsView: NSView, context: Context) {}
  }
}

/// A kind's icon in its colour, as a menu shows it: AppKit draws the menu, and tints a symbol
/// given to it as SwiftUI's in the text's colour.
@MainActor
enum MomentMenuIcon {
  private struct Key: Hashable {
    let kind: ConversationMomentKind
    let theme: ConversationTheme
  }

  private static var images: [Key: NSImage] = [:]

  static func image(of kind: ConversationMomentKind, theme: ConversationTheme) -> NSImage {
    let key = Key(kind: kind, theme: theme)
    if let image = images[key] { return image }
    let renderer = ImageRenderer(
      content: MomentIcon(
        symbol: MomentPresentation.symbol(of: kind),
        color: MomentPresentation.color(of: kind, theme: theme), size: 12
      )
      .environment(\.colorScheme, theme.colorScheme))
    renderer.scale = NSScreen.main?.backingScaleFactor ?? 2
    let image = renderer.nsImage ?? NSImage()
    image.isTemplate = false
    images[key] = image
    return image
  }
}

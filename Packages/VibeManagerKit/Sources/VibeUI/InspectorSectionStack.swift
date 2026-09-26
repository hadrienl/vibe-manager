import AppKit
import SwiftUI
import VibeApplication

/// A section of the context column, as it declares itself (#66): what it is called, how it sizes,
/// what it says folded, and what it shows. Where it goes, whether it is folded and how tall it is
/// are the arrangement's, never the section's.
struct InspectorSectionDescriptor: Identifiable {
  enum Sizing: Equatable {
    /// Takes the height it is given, and scrolls itself: a list, an editor.
    case fill(minimum: Double)
    /// Never taller than its content, which the column puts in a scroll view of its own.
    case fitting(minimum: Double)

    var minimum: Double {
      switch self {
      case .fill(let minimum), .fitting(let minimum): return minimum
      }
    }

    var isFitting: Bool {
      if case .fitting = self { return true }
      return false
    }
  }

  let id: InspectorSectionID
  let title: String
  let systemImage: String
  let sizing: Sizing
  /// Shown beside the title once folded: what the section holds, in a few words.
  var summary: AnyView?
  /// On the right of the header, folded or not: Switch…, Read Again…
  var accessory: AnyView?
  let content: AnyView
  var accessibilityIdentifier: String?
}

/// The context column: every section of it stacked, each with its header, the unfolded ones with a
/// handle between them. Knows nothing of any section in particular.
///
/// Each unfolded section scrolls on its own: a list of five thousand files in Git never pushes
/// the notes out of reach.
struct InspectorSectionStack: View {
  /// In their default order.
  let sections: [InspectorSectionDescriptor]
  let layout: WorkspaceLayoutController

  static let headerHeight: Double = 28

  /// The heights shown while a handle is dragged. Written to the arrangement once it is let go.
  @State private var live: [InspectorSectionID: Double]?
  /// The height the content of each `.fitting` section asks for.
  @State private var contentHeights: [InspectorSectionID: Double] = [:]
  @State private var drag: HeaderDrag?
  /// Where each section sits in the stack, header and body, to know where a dragged header goes.
  @State private var frames: [InspectorSectionID: CGRect] = [:]

  private static let space = "inspector-sections"

  var body: some View {
    let shown = sections.map(\.id)
    let arrangement = layout.inspectorSections
    let byID = Dictionary(sections.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
    let ordered = arrangement.order(of: shown).compactMap { byID[$0] }
    let unfolded = ordered.filter { !arrangement.isCollapsed($0.id) }
    GeometryReader { proxy in
      let heights = heights(
        for: unfolded, in: Double(proxy.size.height), headers: ordered.count,
        arrangement: arrangement)
      let needed =
        Double(ordered.count) * Self.headerHeight
        + Double(max(unfolded.count - 1, 0)) * Double(SplitHandle.thickness)
        + unfolded.reduce(0) { $0 + (heights[$1.id] ?? 0) }
      let stack = VStack(spacing: 0) {
        ForEach(ordered) { section in
          sectionView(
            section, ordered: ordered, unfolded: unfolded, heights: heights, shown: shown)
        }
        Spacer(minLength: 0)
      }
      .coordinateSpace(name: Self.space)
      .onPreferenceChange(SectionFrames.self) { frames = $0 }
      // Only when the minimums do not fit: otherwise each section scrolls on its own, and the
      // column itself never does.
      if needed > Double(proxy.size.height) + 0.5 {
        ScrollView { stack }
      } else {
        stack.frame(height: proxy.size.height, alignment: .top)
      }
    }
  }

  @ViewBuilder
  private func sectionView(
    _ section: InspectorSectionDescriptor, ordered: [InspectorSectionDescriptor],
    unfolded: [InspectorSectionDescriptor], heights: [InspectorSectionID: Double],
    shown: [InspectorSectionID]
  ) -> some View {
    let index = ordered.firstIndex { $0.id == section.id } ?? 0
    let isCollapsed = layout.inspectorSections.isCollapsed(section.id)
    VStack(spacing: 0) {
      InspectorSectionHeader(
        section: section,
        isCollapsed: isCollapsed,
        canMoveUp: index > 0,
        canMoveDown: index < ordered.count - 1,
        isDragged: drag?.id == section.id,
        isDefaultArrangement: layout.isInspectorArrangementDefault,
        toggle: { all in
          if all {
            layout.setAllSectionsCollapsed(!isCollapsed, among: shown)
          } else {
            layout.setSectionCollapsed(section.id, !isCollapsed)
          }
        },
        collapseOthers: { layout.collapseOtherSections(than: section.id, among: shown) },
        move: { layout.moveSection(section.id, by: $0, among: shown) },
        reset: { layout.resetInspectorSections() },
        dragChanged: { location in
          drag = HeaderDrag(id: section.id, insertion: insertion(at: location, in: ordered))
        },
        dragEnded: { location in
          defer { drag = nil }
          drop(section.id, at: insertion(at: location, in: ordered), in: ordered, shown: shown)
        },
        space: Self.space
      )
      if !isCollapsed {
        sectionBody(section, height: heights[section.id] ?? section.sizing.minimum)
        if let next = unfolded.drop(while: { $0.id != section.id }).dropFirst().first {
          handle(between: section, and: next, heights: heights)
        }
      }
    }
    // Over the sections rather than between them: a mark that took room would move the very
    // sections the pointer is compared with.
    .overlay(alignment: .top) {
      if drag?.insertion == index { InsertionMark().offset(y: -1.5) }
    }
    .overlay(alignment: .bottom) {
      if index == ordered.count - 1, drag?.insertion == ordered.count {
        InsertionMark().offset(y: 1.5)
      }
    }
    .background {
      GeometryReader { proxy in
        Color.clear.preference(
          key: SectionFrames.self, value: [section.id: proxy.frame(in: .named(Self.space))])
      }
    }
  }

  @ViewBuilder
  private func sectionBody(_ section: InspectorSectionDescriptor, height: Double) -> some View {
    Group {
      switch section.sizing {
      case .fill:
        section.content
      case .fitting:
        ScrollView {
          section.content
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .onGeometryChange(for: Double.self) {
              Double($0.size.height)
            } action: { height in
              contentHeights[section.id] = height
            }
        }
      }
    }
    .frame(height: height)
    .frame(maxWidth: .infinity)
    .clipped()
    .accessibilityIdentifier(section.accessibilityIdentifier ?? "inspector-\(section.id)")
  }

  private func handle(
    between above: InspectorSectionDescriptor, and below: InspectorSectionDescriptor,
    heights: [InspectorSectionID: Double]
  ) -> some View {
    let upper = heights[above.id] ?? above.sizing.minimum
    let lower = heights[below.id] ?? below.sizing.minimum
    let total = upper + lower
    let range = Self.range(above: above, below: below, total: total, contentHeights: contentHeights)
    let share = total > 0 ? Int((upper / total * 100).rounded()) : 50
    return SplitHandle(
      axis: .vertical,
      length: upper,
      range: range,
      label: Text(
        "Divider between \(above.title) and \(below.title)", bundle: .module,
        comment: "Two sections of the inspector: Git, Notes."),
      value: Text(
        "\(share) percent for \(above.title)", bundle: .module,
        comment: "The share of two sections' height given to the first one, and its name."),
      step: max(total * 0.05, 8),
      onChange: { upper in
        var next = live ?? heights
        next[above.id] = upper
        next[below.id] = total - upper
        live = next
      },
      onEnded: {
        if let live { layout.resizeSections(to: live) }
        live = nil
      },
      onDoubleClick: {
        // Both halves the same, as far as their bounds allow.
        let half = min(max(total / 2, range.lowerBound), range.upperBound)
        var next = heights
        next[above.id] = half
        next[below.id] = total - half
        layout.resizeSections(to: next)
      }
    )
  }

  /// How far a handle moves: neither section under its minimum, nor over its content.
  static func range(
    above: InspectorSectionDescriptor, below: InspectorSectionDescriptor, total: Double,
    contentHeights: [InspectorSectionID: Double]
  ) -> ClosedRange<Double> {
    func maximum(_ section: InspectorSectionDescriptor) -> Double {
      guard section.sizing.isFitting, let content = contentHeights[section.id] else {
        return .infinity
      }
      return max(content, section.sizing.minimum)
    }
    let lower = max(above.sizing.minimum, total - maximum(below))
    let upper = min(total - below.sizing.minimum, maximum(above))
    return lower <= upper ? lower...upper : lower...lower
  }

  private func heights(
    for unfolded: [InspectorSectionDescriptor], in height: Double, headers: Int,
    arrangement: InspectorArrangement
  ) -> [InspectorSectionID: Double] {
    if let live { return live }
    let available =
      height - Double(headers) * Self.headerHeight
      - Double(max(unfolded.count - 1, 0)) * Double(SplitHandle.thickness)
    return InspectorHeights.distribute(
      available,
      among: unfolded.map { section in
        InspectorHeights.Demand(
          id: section.id,
          weight: arrangement.weight(section.id),
          minimum: section.sizing.minimum,
          maximum: section.sizing.isFitting ? contentHeights[section.id] : nil)
      })
  }

  // MARK: - Moving a section by its header

  /// The gap a header dragged to `location` would land in: before the first section whose middle
  /// is below it.
  private func insertion(at location: CGPoint, in ordered: [InspectorSectionDescriptor]) -> Int {
    ordered.firstIndex { section in
      guard let frame = frames[section.id] else { return false }
      return Double(location.y) < Double(frame.midY)
    } ?? ordered.count
  }

  private func drop(
    _ id: InspectorSectionID, at insertion: Int, in ordered: [InspectorSectionDescriptor],
    shown: [InspectorSectionID]
  ) {
    guard let from = ordered.firstIndex(where: { $0.id == id }),
      insertion != from, insertion != from + 1
    else { return }
    if insertion < ordered.count {
      layout.moveSection(id, to: ordered[insertion].id, after: false, among: shown)
    } else if let last = ordered.last {
      layout.moveSection(id, to: last.id, after: true, among: shown)
    }
  }
}

private struct HeaderDrag: Equatable {
  let id: InspectorSectionID
  let insertion: Int
}

private struct SectionFrames: PreferenceKey {
  static let defaultValue: [InspectorSectionID: CGRect] = [:]

  static func reduce(
    value: inout [InspectorSectionID: CGRect], nextValue: () -> [InspectorSectionID: CGRect]
  ) {
    value.merge(nextValue()) { $1 }
  }
}

/// Where a dragged header will land.
private struct InsertionMark: View {
  var body: some View {
    Capsule()
      .fill(Color.accentColor)
      .frame(height: 3)
      .padding(.horizontal, 4)
      .accessibilityHidden(true)
  }
}

/// Chevron, icon, title, what the section holds once folded, and its own actions. A click folds or
/// unfolds it, ⌥-click every section; a drag moves it; its menu moves it too.
struct InspectorSectionHeader: View {
  let section: InspectorSectionDescriptor
  let isCollapsed: Bool
  let canMoveUp: Bool
  let canMoveDown: Bool
  let isDragged: Bool
  let isDefaultArrangement: Bool
  /// `true`: every section, as ⌥-click does.
  let toggle: (_ all: Bool) -> Void
  let collapseOthers: () -> Void
  let move: (Int) -> Void
  let reset: () -> Void
  let dragChanged: (CGPoint) -> Void
  let dragEnded: (CGPoint) -> Void
  let space: String

  /// A drag ends with the button released under the pointer: that release is not a click.
  @State private var isDragging = false
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  var body: some View {
    HStack(spacing: 6) {
      Button {
        guard !isDragging else { return }
        toggle(NSEvent.modifierFlags.contains(.option))
      } label: {
        HStack(spacing: 6) {
          Image(systemName: "chevron.right")
            .font(.caption2.weight(.semibold))
            .foregroundStyle(.secondary)
            .rotationEffect(.degrees(isCollapsed ? 0 : 90))
            .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: isCollapsed)
            .frame(width: 12)
          Image(systemName: section.systemImage)
            .font(.caption)
            .foregroundStyle(.secondary)
            .frame(width: 16)
          Text(section.title)
            .font(.subheadline.weight(.semibold))
            .lineLimit(1)
            .layoutPriority(2)
          if isCollapsed, let summary = section.summary {
            summary
              .font(.caption)
              .foregroundStyle(.tertiary)
              .lineLimit(1)
              .truncationMode(.tail)
          }
          Spacer(minLength: 0)
        }
        .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      .help(
        isCollapsed
          ? Text("Show this section. Option-click shows them all.", bundle: .module)
          : Text("Hide this section. Option-click hides them all.", bundle: .module)
      )
      .accessibilityLabel(Text(section.title))
      .accessibilityValue(
        isCollapsed
          ? Text("Collapsed", bundle: .module) : Text("Expanded", bundle: .module)
      )
      .accessibilityAddTraits(.isHeader)
      .accessibilityAction(named: Text("Move Up", bundle: .module)) { if canMoveUp { move(-1) } }
      .accessibilityAction(named: Text("Move Down", bundle: .module)) {
        if canMoveDown { move(1) }
      }
      .accessibilityAction(named: Text("Collapse Others", bundle: .module), collapseOthers)
      .onKeyPress(keys: [.upArrow, .downArrow], phases: .down) { press in
        guard press.modifiers.contains(.command), press.modifiers.contains(.option) else {
          return .ignored
        }
        let offset = press.key == .upArrow ? -1 : 1
        guard offset < 0 ? canMoveUp : canMoveDown else { return .handled }
        move(offset)
        return .handled
      }

      if let accessory = section.accessory {
        accessory
          .layoutPriority(1)
      }
    }
    .padding(.horizontal, 8)
    .frame(height: InspectorSectionStack.headerHeight)
    .frame(maxWidth: .infinity)
    .background(.quinary)
    .overlay(alignment: .bottom) { Divider() }
    .opacity(isDragged ? 0.5 : 1)
    // Beside the button's click, not instead of it: the button would otherwise keep the drag.
    .simultaneousGesture(
      DragGesture(minimumDistance: 6, coordinateSpace: .named(space))
        .onChanged { value in
          isDragging = true
          dragChanged(value.location)
        }
        .onEnded { value in
          dragEnded(value.location)
          // The button hears the release after the gesture: it must still know it was a drag.
          Task { @MainActor in isDragging = false }
        }
    )
    .contextMenu {
      Button {
        toggle(false)
      } label: {
        isCollapsed
          ? Text("Expand", bundle: .module, comment: "Shows a section of the inspector.")
          : Text("Collapse", bundle: .module, comment: "Hides a section of the inspector.")
      }
      Button(action: collapseOthers) {
        Text("Collapse Others", bundle: .module)
      }
      Divider()
      Button {
        move(-1)
      } label: {
        Text("Move Up", bundle: .module)
      }
      .keyboardShortcut(.upArrow, modifiers: [.command, .option])
      .disabled(!canMoveUp)
      Button {
        move(1)
      } label: {
        Text("Move Down", bundle: .module)
      }
      .keyboardShortcut(.downArrow, modifiers: [.command, .option])
      .disabled(!canMoveDown)
      Divider()
      Button(action: reset) {
        Text("Reset Column Layout", bundle: .module)
      }
      .disabled(isDefaultArrangement)
    }
  }
}

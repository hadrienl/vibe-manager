import SwiftUI

/// How tightly the status bar of a session draws its buttons (#575): the agent, the effort and the
/// usage give up words together, step by step, as the bar gets narrower.
///
/// Chosen once for the whole bar from its width, rather than by each button on its own: a bar
/// where one button is short and its neighbour is not reads as a mistake. Each button still falls
/// back on a shorter form of its own when even its step does not fit — a long model's name.
public enum StatusBarDensity: Int, CaseIterable, Comparable, Sendable {
  /// "Claude Code · Opus 5.5", "Effort: High", the context and the cost.
  case full
  /// The agent's model alone.
  case model
  /// The effort's level alone, and the context without the cost.
  case level
  /// The usage's gauge alone. Kept for the usage's button (#574): the agent and the effort draw
  /// it as `.level`.
  case gauge
  /// The agent and the effort as icons too.
  case icons

  public static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }

  /// The width a bar needs to draw each step, the step itself left out: the widest step a bar of
  /// `width` points takes. Measured on the longest labels English and French give, a Codex model
  /// on the agent's button (`StatusBarLayoutTests`).
  static let minimumWidths: [(density: Self, width: CGFloat)] = [
    (.full, 700), (.model, 560), (.level, 480), (.gauge, 440),
  ]

  /// The widest step that fits a bar `width` points wide.
  public static func fitting(_ width: CGFloat) -> Self {
    minimumWidths.first { width >= $0.width }?.density ?? .icons
  }

  /// This step, then each narrower one: the forms a button may fall back on, in that order.
  public var andNarrower: [Self] {
    Self.allCases.filter { $0 >= self }
  }
}

extension EnvironmentValues {
  /// The step the status bar is drawn at. `.full` outside one.
  @Entry public var statusBarDensity: StatusBarDensity = .full
}

/// Where one item of the status bar is drawn, in the bar: what a test reads to see that none is
/// drawn over another or out of the bar. Only reported while `reportsStatusBarItems` is set, never
/// in the application.
public struct StatusBarItemFrame: Equatable, Sendable {
  public let name: String
  public let frame: CGRect
}

public struct StatusBarItemFrames: PreferenceKey {
  public static let defaultValue: [StatusBarItemFrame] = []

  public static func reduce(
    value: inout [StatusBarItemFrame], nextValue: () -> [StatusBarItemFrame]
  ) {
    value += nextValue()
  }
}

extension EnvironmentValues {
  @Entry public var reportsStatusBarItems = false
}

extension View {
  /// Reports where this item of the status bar is drawn, when a test asks.
  public func statusBarItem(_ name: String) -> some View {
    modifier(StatusBarItemReport(name: name))
  }
}

/// The bar's own space, the one its items are reported in.
let statusBarSpace = "status-bar"

private struct StatusBarItemReport: ViewModifier {
  let name: String
  @Environment(\.reportsStatusBarItems) private var reports

  func body(content: Content) -> some View {
    if reports {
      content.background {
        GeometryReader { proxy in
          Color.clear.preference(
            key: StatusBarItemFrames.self,
            value: [StatusBarItemFrame(name: name, frame: proxy.frame(in: .named(statusBarSpace)))])
        }
      }
    } else {
      content
    }
  }
}

import CompanionCore
import SwiftUI

/// The session's icon, as the Mac's sidebar draws it — its symbol on its colour — with what the
/// agent does as a dot on its corner: orange when it waits for the user, blue at work.
struct SessionBadge: View {
  let appearance: RemoteAppearance
  let activity: RemoteActivity
  var size: CGFloat = 34
  @Environment(RemoteChannel.self) private var channel

  var body: some View {
    shape
      .frame(width: size, height: size)
      .overlay(alignment: .bottomTrailing) {
        if let dot {
          Circle()
            .fill(dot)
            .frame(width: size * 0.36, height: size * 0.36)
            .overlay(Circle().stroke(Color(.systemBackground), lineWidth: 2.5))
            .offset(x: 3, y: 3)
        }
      }
      .accessibilityHidden(true)
  }

  /// The project's icon when the session wears one and it is here; its symbol on its colour
  /// otherwise.
  @ViewBuilder private var shape: some View {
    if let id = appearance.iconID, let image = channel.icon(id) {
      Image(uiImage: image)
        .resizable()
        .interpolation(.high)
        .scaledToFit()
    } else {
      RoundedRectangle(cornerRadius: size * 0.27, style: .continuous)
        .fill(Color(hex: appearance.color) ?? .gray)
        .overlay {
          Image(systemName: appearance.symbol)
            .font(.system(size: size * 0.48, weight: .semibold))
            .foregroundStyle(.white)
        }
    }
  }

  private var dot: Color? {
    switch activity {
    case .needsAttention: .orange
    case .working: .blue
    case .idle, .stopped: nil
    }
  }
}

extension Color {
  init(light: (Double, Double, Double), dark: (Double, Double, Double)) {
    self.init(
      uiColor: UIColor { traits in
        let c = traits.userInterfaceStyle == .dark ? dark : light
        return UIColor(red: c.0, green: c.1, blue: c.2, alpha: 1)
      })
  }

  /// `#RRGGBB`, as the Mac stores a session's colour.
  init?(hex: String) {
    let digits = hex.trimmingCharacters(in: CharacterSet(charactersIn: "# "))
    guard digits.count == 6, let value = UInt32(digits, radix: 16) else { return nil }
    self.init(
      red: Double((value >> 16) & 0xFF) / 255, green: Double((value >> 8) & 0xFF) / 255,
      blue: Double(value & 0xFF) / 255)
  }
}

extension RemoteTaskStatus {
  var label: LocalizedStringKey {
    switch self {
    case .todo: "À faire"
    case .doing: "En cours"
    case .waiting: "En attente"
    case .done: "Terminé"
    case .archived: "Archivée"
    }
  }

  /// The Mac's symbols and colours (`SessionTaskStatusPresentation`).
  var symbol: String {
    switch self {
    case .todo: "circle.dashed"
    case .doing: "circle.lefthalf.filled"
    case .waiting: "pause.circle"
    case .done: "checkmark.circle.fill"
    case .archived: "archivebox"
    }
  }

  var tint: Color {
    switch self {
    // Slate rather than grey, so that À faire is not mistaken for Archivée.
    case .todo: Color(light: (0.42, 0.46, 0.53), dark: (0.49, 0.53, 0.60))
    case .doing: .blue
    case .waiting: .purple
    // The system green is too light under white text.
    case .done: Color(light: (0.12, 0.54, 0.23), dark: (0.14, 0.57, 0.25))
    case .archived: .gray
    }
  }

  /// What its swipe button says: Archiver rather than Archivée.
  var buttonTitle: LocalizedStringKey {
    self == .archived ? "Archiver" : label
  }

  /// The four columns of the Mac's sidebar.
  static let columns: [RemoteTaskStatus] = [.todo, .doing, .waiting, .done]

  /// What a swipe offers, nearest first: the columns before, and after — archiving from Terminé
  /// alone, as on the Mac.
  var previous: [RemoteTaskStatus] {
    guard let index = Self.columns.firstIndex(of: self) else { return [.done] }
    return Self.columns[..<index].reversed()
  }

  var next: [RemoteTaskStatus] {
    guard let index = Self.columns.firstIndex(of: self) else { return [] }
    return Array(Self.columns[(index + 1)...]) + (self == .done ? [.archived] : [])
  }
}

extension RemoteSession {
  /// The second line of its row: what it waits for, or who it is.
  var subtitle: String {
    if let detail, activity == .needsAttention { return detail }
    switch activity {
    case .working: return "\(agentName) · au travail"
    case .needsAttention: return "\(agentName) · attend ta réponse"
    case .idle: return "\(agentName) · à toi de jouer"
    case .stopped: return agentName
    }
  }
}

import SwiftUI

/// Whether a session coordinates sessions of its own, as its composer offers it (#352).
public struct ComposerCoordination {
  public let isOn: Bool
  public let set: (Bool) -> Void

  public init(isOn: Bool, set: @escaping (Bool) -> Void) {
    self.isOn = isOn
    self.set = set
  }
}

/// The “Coordinate” chip of a composer (#352): turned on, the session's agent may create and follow
/// sessions of its own, one per task. In the new session's draft and in a session's conversation.
public struct CoordinateToggle: View {
  @Binding private var isOn: Bool
  private let font: Font

  public init(isOn: Binding<Bool>, font: Font = .caption) {
    _isOn = isOn
    self.font = font
  }

  public var body: some View {
    Toggle(isOn: $isOn) {
      Label {
        Text(
          "Coordinate", bundle: .module,
          comment: "A composer's chip: the agent may create sessions.")
      } icon: {
        Image(systemName: "person.2")
      }
    }
    .toggleStyle(CoordinateToggleStyle(font: font))
    .help(
      isOn
        ? Text(
          "The agent can create and follow sessions of its own, one per task. Click to turn it off.",
          bundle: .module, comment: "The help of the Coordinate chip, turned on.")
        : Text(
          "Let the agent create and follow sessions of its own, one per task.", bundle: .module,
          comment: "The help of the Coordinate chip, turned off.")
    )
    .accessibilityIdentifier("composer-coordinate")
  }
}

private struct CoordinateToggleStyle: ToggleStyle {
  let font: Font

  func makeBody(configuration: Configuration) -> some View {
    let isOn = configuration.isOn
    Button {
      configuration.isOn.toggle()
    } label: {
      configuration.label
        .labelStyle(.titleAndIcon)
        .font(font.weight(isOn ? .semibold : .regular))
        .foregroundStyle(isOn ? Color.teal : Color.secondary)
        .padding(.horizontal, 9)
        .padding(.vertical, 3)
        .background(Capsule().fill(isOn ? Color.teal.opacity(0.16) : Color.clear))
        .overlay(Capsule().strokeBorder(isOn ? Color.teal : Color.secondary.opacity(0.4)))
        .contentShape(Capsule())
    }
    .buttonStyle(.plain)
    // Read as the switch it is, rather than as a button.
    .accessibilityRepresentation {
      Toggle(isOn: configuration.$isOn) { configuration.label }
    }
  }
}

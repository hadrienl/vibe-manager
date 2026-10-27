import SwiftUI

/// Over the composer: the agent's CLI was updated while the session ran (#409), and Restart puts
/// it on the new build, its conversation resumed — this session, or every open one.
struct AgentUpdateNotice: View {
  let model: ConversationModel
  let update: ConversationAgentUpdate
  @Environment(\.conversationTheme) private var theme
  @Environment(\.conversationAppearance) private var appearance

  var body: some View {
    HStack(alignment: .firstTextBaseline) {
      Label {
        VStack(alignment: .leading, spacing: 2) {
          Text(title)
          if update.isPending {
            Text(
              "It takes effect when the session restarts: as soon as \(update.agentName) is done, its conversation resumed.",
              bundle: .module, comment: "Under the notice of an agent's update: an agent's name.")
            .foregroundStyle(theme.secondaryText.color)
          }
        }
      } icon: {
        Image(systemName: "arrow.triangle.2.circlepath")
      }
      .font(theme.interfaceFont(size: appearance.textSize.scaled(12.5)))
      Spacer()
      if update.isPending {
        closeButton
      } else if update.otherSessionCount > 0 {
        Menu {
          Button {
            model.restartForUpdate?(false)
          } label: {
            Text("This Session", bundle: .module, comment: "A choice of Restart, for an update.")
          }
          Button {
            model.restartForUpdate?(true)
          } label: {
            Text(
              "All Open Sessions (\(update.otherSessionCount + 1))", bundle: .module,
              comment: "A choice of Restart, for an update: how many sessions it restarts.")
          }
        } label: {
          Text("Restart", bundle: .module)
        }
        .fixedSize()
      } else {
        Button {
          model.restartForUpdate?(false)
        } label: {
          Text("Restart", bundle: .module)
        }
      }
      if !update.isPending { closeButton }
    }
  }

  /// Whatever happens, the notice can be put away (#430).
  private var closeButton: some View {
    Button {
      model.closeUpdateNotice?()
    } label: {
      Text("Close", bundle: .module, comment: "Puts away the notice of an agent's update.")
    }
  }

  private var title: String {
    if let installed = update.installedVersion, let running = update.runningVersion {
      return String(
        localized:
          "\(update.agentName) \(installed) is installed. This session still runs \(running).",
        bundle: .module,
        comment: "An agent's name, the version installed, then the version the session runs.")
    }
    return String(
      localized: "A new version of \(update.agentName) is installed.", bundle: .module,
      comment: "An agent's name.")
  }
}

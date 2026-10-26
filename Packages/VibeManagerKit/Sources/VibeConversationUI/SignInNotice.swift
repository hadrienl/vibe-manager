import SwiftUI

/// Over the composer: the agent stopped because its CLI's sign-in expired (#410). Sign In opens
/// the browser on the sign-in page, once for every session of that agent; signed in, each one is
/// resumed and handed back the prompt that failed.
struct SignInNotice: View {
  let model: ConversationModel
  let signIn: ConversationSignIn
  @Environment(\.conversationTheme) private var theme
  @Environment(\.conversationAppearance) private var appearance

  var body: some View {
    HStack(alignment: .firstTextBaseline) {
      Label {
        VStack(alignment: .leading, spacing: 2) {
          Text(title)
          if let detail {
            Text(detail)
              .foregroundStyle(theme.secondaryText.color)
              .lineLimit(3)
              .textSelection(.enabled)
          }
        }
      } icon: {
        Image(systemName: symbol)
      }
      .font(theme.interfaceFont(size: appearance.textSize.scaled(12.5)))
      Spacer()
      actions
    }
  }

  @ViewBuilder
  private var actions: some View {
    switch signIn.state {
    case .expired where signIn.route == .elsewhere, .failed where signIn.route == .elsewhere:
      EmptyView()
    case .expired:
      // For an account the browser does not sign in — Console, SSO —, as for one it did not.
      signInInTerminal
      if signIn.route == .browser {
        Button {
          model.startSignIn?()
        } label: {
          Text(
            "Sign In", bundle: .module, comment: "Signs an agent's CLI in again, in the browser.")
        }
      }
    case .signingIn:
      ProgressView().controlSize(.small)
      Button {
        model.cancelSignIn?()
      } label: {
        Text("Cancel", bundle: .module)
      }
    case .failed:
      signInInTerminal
      if signIn.route == .browser {
        Button {
          model.startSignIn?()
        } label: {
          Text("Try Again", bundle: .module)
        }
      }
    case .signedIn(let canResume, let waiting):
      // What waits is seen, finished or cleared there.
      if waiting != nil {
        Button {
          model.showTerminal?()
        } label: {
          Text("Show the Terminal", bundle: .module)
        }
      }
      if canResume {
        Button {
          model.resumeAfterSignIn?()
        } label: {
          Text(
            "Resume", bundle: .module,
            comment: "Restarts a session signed in again, and types back the prompt that failed.")
        }
      }
    case .resuming:
      ProgressView().controlSize(.small)
    }
  }

  private var signInInTerminal: some View {
    Button {
      model.signInInTerminal?()
    } label: {
      Text(
        "Sign In in the Terminal", bundle: .module,
        comment: "Types the CLI's own /login into the session's terminal.")
    }
  }

  private var symbol: String {
    switch signIn.state {
    case .signedIn, .resuming: "checkmark.circle"
    default: "person.crop.circle.badge.exclamationmark"
    }
  }

  private var title: String {
    switch signIn.state {
    case .expired:
      String(
        localized: "The sign-in of \(signIn.agentName) has expired.", bundle: .module,
        comment: "An agent's name.")
    case .signingIn:
      String(
        localized: "Signing in to \(signIn.agentName) in the browser…", bundle: .module,
        comment: "An agent's name.")
    case .failed:
      String(
        localized: "\(signIn.agentName) is still not signed in.", bundle: .module,
        comment: "An agent's name.")
    case .signedIn:
      String(
        localized: "\(signIn.agentName) is signed in again.", bundle: .module,
        comment: "An agent's name.")
    case .resuming:
      String(
        localized: "Signed in. The session resumes where it stopped.", bundle: .module)
    }
  }

  private var detail: String? {
    switch signIn.state {
    case .expired where signIn.route == .elsewhere, .failed where signIn.route == .elsewhere:
      String(
        localized:
          "Signing in again does not change the API key or the provider \(signIn.agentName) uses. Check them, then restart the session.",
        bundle: .module, comment: "An agent's name.")
    case .failed(let detail): detail
    case .signedIn(_, .text(let text?)?):
      String(
        localized: "Resume sends what waits in this session’s prompt: “\(text)”", bundle: .module,
        comment: "The text typed into an agent's prompt, sent once the agent is restarted.")
    case .signedIn(_, .text(nil)?):
      String(
        localized: "Text or work is waiting in this session’s prompt. Resume once it is done.",
        bundle: .module)
    case .signedIn(_, .work?):
      String(
        localized: "Work is still running in this session’s terminal. Resume once it is done.",
        bundle: .module, comment: "A shell or a task the agent runs in the background.")
    default: nil
    }
  }
}

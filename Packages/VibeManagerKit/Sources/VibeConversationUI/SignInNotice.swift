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
    case .expired:
      Button {
        model.startSignIn?()
      } label: {
        Text("Sign In", bundle: .module, comment: "Signs an agent's CLI in again, in the browser.")
      }
    case .signingIn:
      ProgressView().controlSize(.small)
      Button {
        model.cancelSignIn?()
      } label: {
        Text("Cancel", bundle: .module)
      }
    case .failed:
      Button {
        model.signInInTerminal?()
      } label: {
        Text(
          "Sign In in the Terminal", bundle: .module,
          comment: "Types the CLI's own /login into the session's terminal.")
      }
      Button {
        model.startSignIn?()
      } label: {
        Text("Try Again", bundle: .module)
      }
    case .signedIn(let canResume, _):
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
        localized: "Signed in. The session resumes, and its last message is sent again.",
        bundle: .module)
    }
  }

  private var detail: String? {
    switch signIn.state {
    case .failed(let detail): detail
    case .signedIn(_, let textWaiting):
      textWaiting
        ? String(
          localized:
            "Text or work is waiting in this session’s prompt. Resume once it is done.",
          bundle: .module) : nil
    default: nil
    }
  }
}

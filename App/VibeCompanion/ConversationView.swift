import CompanionCore
import SwiftUI

/// A session's conversation, live (#400): the Mac sends it whole at each change while it is shown.
/// What the agent waits for is answered in a card above the field; the field writes to the agent.
struct ConversationView: View {
  let sessionID: String
  @Environment(RemoteChannel.self) private var channel
  @State private var draft = ""
  @FocusState private var fieldFocused: Bool

  private var session: RemoteSession? { channel.sessions.first { $0.id == sessionID } }
  private var conversation: RemoteConversation? {
    channel.conversation?.sessionID == sessionID ? channel.conversation : nil
  }

  var body: some View {
    ScrollView {
      LazyVStack(alignment: .leading, spacing: 10) {
        if conversation == nil {
          ProgressView().frame(maxWidth: .infinity).padding(.top, 40)
        }
        ForEach(conversation?.entries ?? []) { entry in
          EntryView(entry: entry)
        }
        if session?.activity == .working {
          TypingDots().padding(.vertical, 4)
        }
      }
      .padding(.horizontal, 16)
      .padding(.vertical, 12)
    }
    .defaultScrollAnchor(.bottom)
    .scrollDismissesKeyboard(.interactively)
    .safeAreaInset(edge: .bottom, spacing: 0) {
      VStack(spacing: 8) {
        if let request = conversation?.request {
          RequestCard(request: request, sessionID: sessionID)
            .padding(.horizontal, 12)
        }
        inputBar
      }
      .padding(.bottom, 6)
    }
    .navigationTitle(session?.name ?? "")
    .navigationSubtitle(subtitle)
    .navigationBarTitleDisplayMode(.inline)
    .onAppear { channel.show(sessionID) }
    .onDisappear { if channel.conversation?.sessionID == sessionID { channel.show(nil) } }
  }

  private var subtitle: String {
    guard let session else { return "" }
    switch session.activity {
    case .working: return "\(session.agentName) au travail"
    case .needsAttention: return "\(session.agentName) attend ta réponse"
    case .idle: return "\(session.agentName) · à toi de jouer"
    case .stopped: return "\(session.agentName) · arrêté"
    }
  }

  private var inputBar: some View {
    HStack(alignment: .bottom, spacing: 8) {
      TextField(
        "Écrire à \(session?.agentName ?? "l’agent")…", text: $draft, axis: .vertical
      )
      .lineLimit(1...6)
      .focused($fieldFocused)
      .padding(.horizontal, 14)
      .padding(.vertical, 10)
      .glassEffect(.regular.interactive(), in: .rect(cornerRadius: 22))
      Button {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        channel.send(text, to: sessionID)
        draft = ""
      } label: {
        Image(systemName: "arrow.up")
          .font(.body.weight(.bold))
          .frame(width: 30, height: 30)
      }
      .buttonStyle(.glassProminent)
      .buttonBorderShape(.circle)
      .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
      .accessibilityLabel("Envoyer")
    }
    .padding(.horizontal, 12)
  }
}

private struct EntryView: View {
  let entry: RemoteEntry

  var body: some View {
    switch entry.kind {
    case .user(let text):
      Text(verbatim: text)
        .padding(.horizontal, 13)
        .padding(.vertical, 9)
        .foregroundStyle(.white)
        .background(Color.accentColor, in: .rect(cornerRadius: 18))
        .frame(maxWidth: .infinity, alignment: .trailing)
        .padding(.leading, 48)
        .textSelection(.enabled)
    case .agent(let text):
      Text(Self.markdown(text))
        .frame(maxWidth: .infinity, alignment: .leading)
        .textSelection(.enabled)
    case .tool(let symbol, let title, let detail, let running, let failed):
      HStack(spacing: 8) {
        Image(systemName: symbol)
          .foregroundStyle(failed ? Color.red : .secondary)
          .frame(width: 18)
        Text(verbatim: title).lineLimit(1)
        if let detail {
          Text(verbatim: detail).foregroundStyle(.secondary).lineLimit(1)
        }
        Spacer(minLength: 0)
        if running { ProgressView().controlSize(.mini) }
      }
      .font(.footnote)
      .padding(.horizontal, 10)
      .padding(.vertical, 7)
      .background(Color(.secondarySystemBackground), in: .rect(cornerRadius: 10))
    case .notice(let text):
      Text(verbatim: text)
        .font(.caption)
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity)
    }
  }

  static func markdown(_ text: String) -> AttributedString {
    (try? AttributedString(
      markdown: text,
      options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
      ?? AttributedString(text)
  }
}

/// A permission or a question, answered here as on the Mac.
private struct RequestCard: View {
  let request: RemoteRequest
  let sessionID: String
  @Environment(RemoteChannel.self) private var channel
  @State private var selection: Set<String> = []
  @State private var text = ""

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      Label {
        Text(verbatim: request.title).font(.subheadline.weight(.semibold))
      } icon: {
        Image(systemName: request.kind == .permission ? "checkmark.shield" : "questionmark.bubble")
      }
      .foregroundStyle(.orange)
      if let subject = request.subject {
        Text(verbatim: subject)
          .font(.footnote.monospaced())
          .padding(10)
          .frame(maxWidth: .infinity, alignment: .leading)
          .background(Color(.tertiarySystemFill), in: .rect(cornerRadius: 10))
      }
      if request.kind == .permission {
        ForEach(request.choices) { choice in
          Button(role: choice.isDestructive ? .destructive : nil) {
            channel.answer(request, in: sessionID, choiceIDs: [choice.id], text: nil)
          } label: {
            Text(verbatim: choice.label).frame(maxWidth: .infinity, minHeight: 30)
          }
          .buttonStyle(choice.id == "allowOnce" ? AnyButtonStyle(.glassProminent) : AnyButtonStyle(.glass))
        }
      } else {
        ForEach(request.choices) { choice in
          Button {
            toggle(choice.id)
          } label: {
            HStack(alignment: .top, spacing: 10) {
              Image(systemName: selection.contains(choice.id) ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(.tint)
              VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: choice.label).font(.subheadline.weight(.semibold))
                if let detail = choice.detail {
                  Text(verbatim: detail).font(.caption).foregroundStyle(.secondary)
                }
              }
              Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
          }
          .buttonStyle(.plain)
        }
        if request.allowsText {
          TextField("Autre réponse…", text: $text)
            .textFieldStyle(.roundedBorder)
        }
        Button {
          channel.answer(
            request, in: sessionID, choiceIDs: Array(selection),
            text: text.isEmpty ? nil : text)
        } label: {
          Text("Répondre").frame(maxWidth: .infinity, minHeight: 30)
        }
        .buttonStyle(.glassProminent)
        .disabled(selection.isEmpty && text.isEmpty)
      }
    }
    .padding(14)
    .glassEffect(.regular.tint(.orange.opacity(0.12)), in: .rect(cornerRadius: 20))
    .onChange(of: request.id) { _, _ in
      selection = []
      text = ""
    }
  }

  private func toggle(_ id: String) {
    if request.allowsSeveral {
      if selection.contains(id) { selection.remove(id) } else { selection.insert(id) }
    } else {
      selection = [id]
    }
  }
}

/// Either glass style, picked at run time.
private struct AnyButtonStyle: PrimitiveButtonStyle {
  private let make: (Configuration) -> AnyView

  init(_ style: some PrimitiveButtonStyle) {
    make = { AnyView(style.makeBody(configuration: $0)) }
  }

  func makeBody(configuration: Configuration) -> some View { make(configuration) }
}

private struct TypingDots: View {
  var body: some View {
    HStack(spacing: 4) {
      ForEach(0..<3) { index in
        Circle()
          .fill(.secondary)
          .frame(width: 7, height: 7)
          .opacity(1 - Double(index) * 0.3)
      }
    }
    .accessibilityLabel("L’agent travaille")
  }
}

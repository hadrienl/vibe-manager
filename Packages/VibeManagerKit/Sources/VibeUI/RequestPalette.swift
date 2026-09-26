import SwiftUI
import VibeApplication
import VibeDomain

/// The requests of the sessions in the background, over the foot of the sidebar (#40).
///
/// It never reaches the session on screen: it lives in the sidebar's column. Answering types into
/// the terminal of the request's own session; only "Open Session" changes the one on screen.
struct RequestPalette: View {
  @Bindable var model: AppModel
  /// The most height it takes, scrolling past it.
  let maxHeight: CGFloat
  @FocusState private var focusedRequest: AgentRequestID?
  @Namespace private var rotor
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  var body: some View {
    let requests = model.pendingRequests
    Group {
      if requests.isEmpty {
        if let outcome = model.requestOutcome { OutcomeLine(model: model, outcome: outcome) }
      } else if model.isRequestPaletteCollapsed {
        collapsed(count: requests.count)
      } else {
        expanded(requests)
      }
    }
    .animation(reduceMotion ? nil : .snappy, value: requests.map(\.id))
  }

  private func collapsed(count: Int) -> some View {
    Button {
      model.setRequestPaletteCollapsed(false)
    } label: {
      HStack(spacing: 6) {
        Image(systemName: "hand.raised.fill")
          .symbolEffect(.bounce, value: reduceMotion ? 0 : count)
        Text("\(count) waiting", bundle: .module, comment: "The folded palette of requests.")
          .fontWeight(.semibold)
        Spacer(minLength: 0)
        Image(systemName: "chevron.up")
          .font(.caption)
      }
      .foregroundStyle(.orange)
      .padding(.horizontal, 12)
      .padding(.vertical, 8)
      .frame(maxWidth: .infinity)
      .background(.regularMaterial)
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .overlay(alignment: .top) { Divider() }
    .accessibilityLabel(
      Text(
        "Pending requests: \(count). Show", bundle: .module,
        comment: "VoiceOver, on the folded palette of requests.")
    )
    .accessibilityIdentifier("request-palette-collapsed")
  }

  private func expanded(_ requests: [PendingRequest]) -> some View {
    VStack(spacing: 0) {
      header(count: requests.count)
      Divider()
      ViewThatFits(in: .vertical) {
        cards(requests)
        ScrollViewReader { proxy in
          ScrollView {
            cards(requests)
          }
          .onChange(of: focusedRequest) { _, id in
            guard let id else { return }
            withAnimation(reduceMotion ? nil : .snappy) { proxy.scrollTo(id) }
          }
        }
      }
      .frame(maxHeight: maxHeight)
      if let outcome = model.requestOutcome { OutcomeLine(model: model, outcome: outcome) }
    }
    .background(.regularMaterial)
    .overlay(alignment: .top) { Divider() }
    .onKeyPress(.downArrow) { move(by: 1, in: requests) }
    .onKeyPress(.upArrow) { move(by: -1, in: requests) }
    .onKeyPress(.escape) {
      guard focusedRequest != nil else { return .ignored }
      focusedRequest = nil
      model.focusTerminal()
      return .handled
    }
    .onChange(of: model.requestPaletteFocusRequest) {
      focusedRequest = model.revealedRequestID ?? requests.first?.id
    }
    .accessibilityElement(children: .contain)
    .accessibilityLabel(
      Text(
        "Pending requests: \(requests.count)", bundle: .module,
        comment: "VoiceOver, on the palette of requests.")
    )
    .accessibilityRotor(Text("Requests", bundle: .module, comment: "A VoiceOver rotor.")) {
      ForEach(requests) { pending in
        AccessibilityRotorEntry(Text(verbatim: pending.session.name), id: pending.id, in: rotor)
      }
    }
    .accessibilityIdentifier("request-palette")
  }

  private func header(count: Int) -> some View {
    HStack(spacing: 6) {
      Image(systemName: "hand.raised.fill")
        .foregroundStyle(.orange)
        .symbolEffect(.bounce, value: reduceMotion ? 0 : count)
      Text("Pending Requests", bundle: .module, comment: "The title of the palette of requests.")
        .font(.headline)
      Text(verbatim: "\(count)")
        .font(.caption.weight(.semibold).monospacedDigit())
        .padding(.horizontal, 6)
        .padding(.vertical, 1)
        .background(Capsule().fill(.orange.opacity(0.2)))
        .accessibilityHidden(true)
      Spacer()
      Button {
        model.setRequestPaletteCollapsed(true)
      } label: {
        Image(systemName: "chevron.down")
      }
      .buttonStyle(.borderless)
      .help(Text("Fold the requests", bundle: .module))
      .accessibilityLabel(Text("Fold the requests", bundle: .module))
    }
    .padding(.horizontal, 12)
    .padding(.vertical, 8)
  }

  private func cards(_ requests: [PendingRequest]) -> some View {
    LazyVStack(spacing: 8) {
      ForEach(requests) { pending in
        RequestCard(model: model, pending: pending, isFocused: focusedRequest == pending.id)
          .focusable()
          .focused($focusedRequest, equals: pending.id)
          .accessibilityRotorEntry(id: pending.id, in: rotor)
          .id(pending.id)
      }
    }
    .padding(8)
  }

  private func move(by offset: Int, in requests: [PendingRequest]) -> KeyPress.Result {
    guard let current = focusedRequest,
      let index = requests.firstIndex(where: { $0.id == current })
    else { return .ignored }
    let next = min(max(index + offset, 0), requests.count - 1)
    focusedRequest = requests[next].id
    return .handled
  }
}

/// What the last answer did, for a moment.
private struct OutcomeLine: View {
  let model: AppModel
  let outcome: RequestOutcome

  var body: some View {
    Label {
      Text(
        AppModel.announcement(
          of: outcome.answer, outcome: outcome.outcome, sessionName: outcome.sessionName))
    } icon: {
      Image(
        systemName: outcome.outcome == .sent ? "checkmark.circle.fill" : "exclamationmark.circle")
    }
    .font(.caption)
    .foregroundStyle(.secondary)
    .lineLimit(2)
    .padding(.horizontal, 12)
    .padding(.vertical, 6)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(.regularMaterial)
    .task(id: outcome.id) {
      try? await Task.sleep(for: .seconds(outcome.outcome == .sent ? 2 : 5))
      model.dismissRequestOutcome(outcome.id)
    }
  }
}

/// One request: whose it is, what it asks, and the answers its CLI lets be given from here.
struct RequestCard: View {
  let model: AppModel
  let pending: PendingRequest
  let isFocused: Bool
  @State private var choices: [Int: AgentQuestionAnswer] = [:]
  @State private var writingFor: Int?
  @State private var draft = ""
  @FocusState private var isDraftFocused: Bool

  private var request: AgentRequest { pending.request }
  private var answers: Set<AgentAnswerKind> { pending.answering.answers }
  private var isSending: Bool { model.answeringRequestIDs.contains(pending.id) }

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      identity
      Label {
        Text(RequestPresentation.title(of: request.content))
      } icon: {
        Image(systemName: RequestPresentation.symbolName(of: request.content))
      }
      .font(.callout.weight(.semibold))
      .foregroundStyle(.orange)
      content
      if case .inTerminalOnly(let reason) = pending.answering {
        Text(
          RequestPresentation.terminalReason(
            reason, isQuestion: request.kind == .question)
        )
        .font(.caption)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
      }
      actions
    }
    .padding(10)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(.background))
    .overlay(
      RoundedRectangle(cornerRadius: 10, style: .continuous)
        .strokeBorder(
          isFocused ? Color.accentColor : Color.secondary.opacity(0.25),
          lineWidth: isFocused ? 2 : 1)
    )
    .onKeyPress(keys: [.return], phases: .down) { press in
      guard press.modifiers.contains(.command) else { return .ignored }
      model.openSession(for: pending.id)
      return .handled
    }
    .accessibilityElement(children: .contain)
    .accessibilityLabel(Text(verbatim: RequestPresentation.accessibilityLabel(for: pending)))
    .accessibilityActions { accessibilityActions }
    .accessibilityIdentifier("request-card")
  }

  // MARK: - Identity

  private var identity: some View {
    HStack(alignment: .top, spacing: 8) {
      SessionBadge(appearance: pending.session.appearance, size: 22)
      VStack(alignment: .leading, spacing: 1) {
        HStack(alignment: .firstTextBaseline) {
          Text(verbatim: pending.session.name)
            .fontWeight(.semibold)
            .lineLimit(1)
          Spacer(minLength: 4)
          TimelineView(.periodic(from: request.receivedAt, by: 30)) { _ in
            Text(request.receivedAt, format: .relative(presentation: .named))
              .font(.caption)
              .foregroundStyle(.secondary)
              .monospacedDigit()
          }
        }
        Text(verbatim: identityLine)
          .font(.caption)
          .foregroundStyle(.secondary)
          .lineLimit(1)
          .truncationMode(.middle)
          .help(Text(verbatim: pending.folderPath ?? ""))
      }
    }
    .accessibilityHidden(true)
  }

  /// Agent · folder · branch: two sessions of the same name are told apart by where they work.
  private var identityLine: String {
    [pending.agentName, pending.folderName, pending.branch].compactMap { $0 }.joined(
      separator: " · ")
  }

  // MARK: - What it asks

  @ViewBuilder private var content: some View {
    switch request.content {
    case .permission(let permission):
      permissionContent(permission)
    case .questions(let questions):
      ForEach(Array(questions.enumerated()), id: \.offset) { index, question in
        questionContent(question, at: index, of: questions)
      }
      if questions.count > 1, answers.contains(.chooseOption) {
        Button {
          send(.answers(questions.indices.compactMap { choices[$0] }))
        } label: {
          Text("Send Answers", bundle: .module)
        }
        .buttonStyle(.borderedProminent)
        .disabled(choices.count < questions.count || isSending)
      }
    case .plan(let excerpt, let isComplete):
      ScrollView {
        Text(verbatim: DisplaySafeText.visible(excerpt))
          .font(.callout)
          .textSelection(.enabled)
          .frame(maxWidth: .infinity, alignment: .leading)
      }
      .frame(maxHeight: 140)
      if !isComplete {
        Text("The plan goes on in the session.", bundle: .module)
          .font(.caption)
          .foregroundStyle(.secondary)
      }
    case .elicitation, .unreadable:
      EmptyView()
    }
  }

  @ViewBuilder
  private func permissionContent(_ permission: AgentToolPermission) -> some View {
    if let subject = RequestPresentation.subject(of: request.content) {
      Text(verbatim: subject)
        .font(.system(.callout, design: .monospaced))
        .textSelection(.enabled)
        .lineLimit(6)
        .padding(6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 6).fill(.quaternary.opacity(0.6)))
    }
    if let purpose = permission.purpose {
      Text(verbatim: DisplaySafeText.visible(purpose))
        .font(.caption)
        .foregroundStyle(.secondary)
        .lineLimit(3)
    }
    if let folder = permission.workingDirectory, folder != pending.folderPath {
      Label {
        Text(verbatim: DisplaySafeText.visible(folder))
      } icon: {
        Image(systemName: "folder")
      }
      .font(.caption)
      .foregroundStyle(.secondary)
      .lineLimit(1)
      .truncationMode(.middle)
    }
    if let details = permission.details {
      DisclosureGroup {
        ScrollView {
          Text(verbatim: DisplaySafeText.visible(details))
            .font(.system(.caption, design: .monospaced))
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxHeight: 200)
      } label: {
        Text("Show All", bundle: .module, comment: "Unfolds everything a tool was handed.")
          .font(.caption)
      }
    }
  }

  @ViewBuilder
  private func questionContent(_ question: AgentQuestion, at index: Int, of all: [AgentQuestion])
    -> some View
  {
    VStack(alignment: .leading, spacing: 4) {
      if let header = question.header {
        Text(verbatim: DisplaySafeText.visible(header))
          .font(.caption2.weight(.semibold))
          .padding(.horizontal, 6)
          .padding(.vertical, 1)
          .background(Capsule().fill(.quaternary))
      }
      Text(verbatim: DisplaySafeText.visible(question.text))
        .font(.callout)
        .fixedSize(horizontal: false, vertical: true)
      ForEach(Array(question.options.enumerated()), id: \.offset) { option, choice in
        Button {
          choose(.option(option), for: index, of: all)
        } label: {
          VStack(alignment: .leading, spacing: 1) {
            Text(verbatim: DisplaySafeText.visible(choice.label))
            if let description = choice.description {
              Text(verbatim: DisplaySafeText.visible(description))
                .font(.caption)
                .foregroundStyle(.secondary)
            }
          }
          .frame(maxWidth: .infinity, alignment: .leading)
        }
        .buttonStyle(.bordered)
        .tint(choices[index] == .option(option) ? .accentColor : nil)
        .disabled(!answers.contains(.chooseOption) || isSending)
      }
      if answers.contains(.writeText), question.allowsFreeText {
        if writingFor == index {
          HStack {
            TextField(text: $draft, prompt: Text("Your answer", bundle: .module)) {
              Text("Your answer", bundle: .module)
            }
            .textFieldStyle(.roundedBorder)
            .focused($isDraftFocused)
            .onSubmit { submitDraft(for: index, of: all) }
            .onKeyPress(.escape) {
              writingFor = nil
              model.focusTerminal()
              return .handled
            }
            Button {
              submitDraft(for: index, of: all)
            } label: {
              Image(systemName: "arrow.up.circle.fill")
            }
            .buttonStyle(.borderless)
            .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isSending)
            .accessibilityLabel(Text("Send", bundle: .module))
          }
        } else {
          Button {
            draft = ""
            writingFor = index
            isDraftFocused = true
          } label: {
            Text("Other Answer…", bundle: .module, comment: "Answers a question in free text.")
          }
          .buttonStyle(.link)
          .font(.caption)
        }
      }
    }
  }

  // MARK: - Answers

  @ViewBuilder private var actions: some View {
    HStack(spacing: 6) {
      switch request.content {
      case .permission(let permission):
        if answers.contains(.allowOnce) {
          Button {
            send(.allowOnce)
          } label: {
            Text("Allow", bundle: .module, comment: "Allows what an agent asks, this once.")
          }
          .buttonStyle(.borderedProminent)
        }
        if answers.contains(.allowAlways), let allow = permission.alwaysAllow {
          Button {
            send(.allowAlways)
          } label: {
            Text("Always", bundle: .module, comment: "Allows what an agent asks, from now on.")
          }
          .help(Text(RequestPresentation.alwaysAllowTitle(allow)))
          .accessibilityLabel(Text(RequestPresentation.alwaysAllowTitle(allow)))
        }
        if answers.contains(.deny) { denyButton }
      case .unreadable:
        if answers.contains(.deny) { denyButton }
      case .plan:
        if answers.contains(.approvePlan) {
          Menu {
            Button {
              send(.approvePlan(.acceptEdits))
            } label: {
              Text("Approve, Accepting Edits", bundle: .module)
            }
            Button {
              send(.approvePlan(.reviewEdits))
            } label: {
              Text("Approve, Reviewing Each Edit", bundle: .module)
            }
          } label: {
            Text("Approve", bundle: .module, comment: "Approves an agent's plan.")
          }
          .fixedSize()
        }
        if answers.contains(.rejectPlan) {
          Button {
            send(.rejectPlan)
          } label: {
            Text("Reject", bundle: .module, comment: "Rejects an agent's plan.")
          }
        }
      case .questions, .elicitation:
        EmptyView()
      }
      Spacer(minLength: 0)
      openButton
    }
    .disabled(isSending)
    .controlSize(.small)
  }

  private var denyButton: some View {
    Button {
      send(.deny)
    } label: {
      Text("Refuse", bundle: .module, comment: "Refuses what an agent asks.")
    }
  }

  @ViewBuilder private var openButton: some View {
    let isOnlyWay = answers.isEmpty
    Button {
      model.openSession(for: pending.id)
    } label: {
      Label {
        Text("Open Session", bundle: .module)
      } icon: {
        Image(systemName: "arrow.up.forward.app")
      }
      .labelStyle(isOnlyWay ? AnyLabelStyle(.titleAndIcon) : AnyLabelStyle(.iconOnly))
    }
    .buttonStyle(isOnlyWay ? AnyButtonStyle(.borderedProminent) : AnyButtonStyle(.borderless))
    .help(Text("Open Session", bundle: .module))
  }

  @ViewBuilder private var accessibilityActions: some View {
    if answers.contains(.allowOnce) {
      Button {
        send(.allowOnce)
      } label: {
        Text("Allow", bundle: .module)
      }
    }
    if answers.contains(.allowAlways) {
      Button {
        send(.allowAlways)
      } label: {
        Text("Always", bundle: .module)
      }
    }
    if answers.contains(.deny) {
      Button {
        send(.deny)
      } label: {
        Text("Refuse", bundle: .module)
      }
    }
    Button {
      model.openSession(for: pending.id)
    } label: {
      Text("Open Session", bundle: .module)
    }
  }

  private func choose(_ answer: AgentQuestionAnswer, for index: Int, of all: [AgentQuestion]) {
    if all.count == 1 {
      send(.answers([answer]))
    } else {
      choices[index] = answer
    }
  }

  private func submitDraft(for index: Int, of all: [AgentQuestion]) {
    let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !text.isEmpty else { return }
    writingFor = nil
    choose(.text(text), for: index, of: all)
    // The keyboard goes back where it was: the session on screen.
    model.focusTerminal()
  }

  private func send(_ answer: AgentAnswer) {
    Task { await model.answer(answer, to: pending.id) }
  }
}

/// A label style chosen at run time.
private struct AnyLabelStyle: LabelStyle {
  private let make: (Configuration) -> AnyView

  init<Style: LabelStyle>(_ style: Style) {
    make = { AnyView(style.makeBody(configuration: $0)) }
  }

  func makeBody(configuration: Configuration) -> some View {
    make(configuration)
  }
}

/// A button style chosen at run time.
private struct AnyButtonStyle: PrimitiveButtonStyle {
  private let make: (Configuration) -> AnyView

  init<Style: PrimitiveButtonStyle>(_ style: Style) {
    make = { AnyView(style.makeBody(configuration: $0)) }
  }

  func makeBody(configuration: Configuration) -> some View {
    make(configuration)
  }
}

/// The palette's count in the toolbar, while the sidebar that holds it is folded.
struct RequestPaletteToolbarButton: View {
  @Bindable var model: AppModel
  @State private var isShowingPalette = false

  var body: some View {
    let count = model.pendingRequests.count
    Button {
      isShowingPalette.toggle()
    } label: {
      Label {
        Text("Pending requests: \(count)", bundle: .module)
      } icon: {
        Image(systemName: "hand.raised.fill")
      }
      .labelStyle(.titleAndIcon)
      .foregroundStyle(.orange)
    }
    .help(Text("Pending requests: \(count)", bundle: .module))
    .popover(isPresented: $isShowingPalette, arrowEdge: .bottom) {
      RequestPalette(model: model, maxHeight: 480)
        .frame(width: 340)
        .onAppear { model.setRequestPaletteCollapsed(false) }
    }
    .onChange(of: model.requestPaletteFocusRequest) { isShowingPalette = true }
  }
}

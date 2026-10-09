import AppKit
import SwiftUI
import VibeApplication

/// The composer's microphone (#340): a click starts a dictation, a second one inserts what was
/// said in the draft. What the dictation needs first — the model downloaded, the microphone
/// allowed — is said in a popover from the button.
struct DictationButton: View {
  let model: ConversationModel
  let dictation: DictationController
  let isEnabled: Bool
  /// Whether its session is the one on screen: put away, its dictation is let go of.
  let isActive: Bool
  @Environment(\.conversationTheme) private var theme
  /// The progress of a download or a preparation, closed by the user: it goes on, behind the
  /// button, until a click shows it again.
  @State private var hidesProgress = false

  private var owner: ObjectIdentifier { ObjectIdentifier(model) }
  private var isMine: Bool { dictation.concerns(owner) }
  private var isRecording: Bool { isMine && dictation.phase == .recording }
  private var isWorking: Bool {
    guard isMine else { return false }
    switch dictation.phase {
    case .downloading, .preparing, .transcribing: return true
    case .idle, .offeringDownload, .recording: return false
    }
  }

  /// Downloading or preparing for this composer, the progress closed.
  private var isWaitingBehindButton: Bool {
    guard isMine, hidesProgress else { return false }
    switch dictation.phase {
    case .downloading, .preparing: return true
    case .idle, .offeringDownload, .recording, .transcribing: return false
    }
  }

  var body: some View {
    Button {
      if isWaitingBehindButton {
        hidesProgress = false
        return
      }
      toggle()
    } label: {
      Group {
        if isWorking {
          ProgressView().controlSize(.small)
        } else {
          Image(systemName: isRecording ? "stop.fill" : "mic")
            .font(.system(size: isRecording ? 11 : 13, weight: .semibold))
            .foregroundStyle(isRecording ? Color.white : theme.text.color)
        }
      }
      .frame(width: 28, height: 28)
      .background(isRecording ? Color.red : theme.surface.color, in: Circle())
      .overlay(Circle().stroke(isRecording ? Color.clear : theme.border.color))
      .contentShape(Circle())
    }
    .buttonStyle(.plain)
    // A recording can always be stopped: the agent may have asked something meanwhile.
    .disabled(
      !isRecording && !isWaitingBehindButton
        && (!isEnabled || dictation.isBusy(for: owner) || isWorking))
    .onChange(of: isActive) { _, isActive in
      if !isActive { dictation.release(owner) }
    }
    .onDisappear { dictation.release(owner) }
    .accessibilityLabel(
      isRecording
        ? Text("Stop Dictation", bundle: .module) : Text("Dictate", bundle: .module))
    .help(
      isRecording
        ? Text("Stop and insert what you said", bundle: .module)
        : Text("Dictate a message, transcribed on this Mac", bundle: .module))
    .popover(isPresented: popoverBinding, arrowEdge: .top) {
      DictationPopover(dictation: dictation, dictate: toggle)
    }
  }

  private func toggle() {
    hidesProgress = false
    // The field the text goes to, if it has the keyboard now: another field that has it by the
    // time the text is heard must not receive it.
    let field = WeakTextView(PromptComposer.composerTextView(showing: model.draft))
    dictation.toggle(
      DictationController.Request(
        owner: owner, vocabulary: { model.dictationVocabulary() },
        insert: { text in PromptComposer.insertDictation(text, into: model, field: field.view) }))
  }

  /// Shown while the dictation that this composer asked for waits on something, or stopped.
  private var popoverBinding: Binding<Bool> {
    Binding(
      get: {
        guard isMine else { return false }
        if dictation.problem != nil || dictation.isReadyToDictate { return true }
        switch dictation.phase {
        case .offeringDownload: return true
        case .downloading, .preparing: return !hidesProgress
        case .idle, .recording, .transcribing: return false
        }
      },
      set: { isPresented in
        guard !isPresented, isMine else { return }
        // Closed from outside: an offer is declined, a problem read. A download goes on, its
        // progress behind the button.
        switch dictation.phase {
        case .offeringDownload: dictation.cancel()
        case .downloading, .preparing: hidesProgress = true
        case .idle, .recording, .transcribing: break
        }
        dictation.dismissProblem()
      })
  }
}

/// What the dictation waits on, or what stopped it.
struct DictationPopover: View {
  let dictation: DictationController
  /// Starts the dictation, once the model is ready.
  let dictate: () -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      content
    }
    .padding(16)
    .frame(width: 300, alignment: .leading)
  }

  private var size: String {
    ByteCountFormatter.string(
      fromByteCount: dictation.settings.variant.downloadSize, countStyle: .file)
  }

  @ViewBuilder
  private var content: some View {
    if let problem = dictation.problem {
      problemContent(problem)
    } else if dictation.isReadyToDictate {
      Text("The speech model is ready.", bundle: .module).font(.headline)
      Text("Click the microphone to dictate.", bundle: .module)
        .fixedSize(horizontal: false, vertical: true)
      HStack {
        Spacer()
        Button {
          dictate()
        } label: {
          Text("Dictate", bundle: .module)
        }
        .keyboardShortcut(.defaultAction)
      }
    } else {
      switch dictation.phase {
      case .offeringDownload:
        Text("Download the speech model?", bundle: .module).font(.headline)
        Text(
          """
          Dictation runs on this Mac, with Whisper. Its model (\(size)) is downloaded once and \
          kept: what you say never leaves your Mac.
          """,
          bundle: .module
        )
        .fixedSize(horizontal: false, vertical: true)
        HStack {
          Spacer()
          Button {
            dictation.cancel()
          } label: {
            Text("Not Now", bundle: .module)
          }
          .keyboardShortcut(.cancelAction)
          Button {
            dictation.acceptDownload()
          } label: {
            Text("Download", bundle: .module)
          }
          .keyboardShortcut(.defaultAction)
        }
      case .downloading(let fraction):
        Text("Downloading the speech model…", bundle: .module).font(.headline)
        ProgressView(value: fraction)
        HStack {
          Text(verbatim: fraction.formatted(.percent.precision(.fractionLength(0))))
            .foregroundStyle(.secondary)
            .monospacedDigit()
          Spacer()
          Button {
            dictation.cancel()
          } label: {
            Text("Cancel", bundle: .module)
          }
        }
      case .preparing:
        Text("Preparing the speech model…", bundle: .module).font(.headline)
        ProgressView().progressViewStyle(.linear)
        Text("The first time, this can take a minute.", bundle: .module)
          .foregroundStyle(.secondary)
      case .idle, .recording, .transcribing:
        EmptyView()
      }
    }
  }

  @ViewBuilder
  private func problemContent(_ problem: DictationController.Problem) -> some View {
    switch problem {
    case .microphoneDenied:
      Text("Vibe Manager may not use the microphone.", bundle: .module).font(.headline)
      Text(
        "Allow it in System Settings › Privacy & Security › Microphone, then dictate again.",
        bundle: .module
      )
      .fixedSize(horizontal: false, vertical: true)
      HStack {
        Spacer()
        Button {
          dictation.dismissProblem()
          if let url = URL(
            string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")
          {
            NSWorkspace.shared.open(url)
          }
        } label: {
          Text("Open System Settings", bundle: .module)
        }
        .keyboardShortcut(.defaultAction)
      }
    case .noMicrophone:
      Text("No microphone is available.", bundle: .module).font(.headline)
      Text("Connect one, or choose one in System Settings › Sound.", bundle: .module)
        .fixedSize(horizontal: false, vertical: true)
    case .downloadFailed:
      Text("The speech model could not be downloaded.", bundle: .module).font(.headline)
      Text("Check the connection, then dictate again.", bundle: .module)
        .fixedSize(horizontal: false, vertical: true)
    case .nothingHeard:
      Text("Nothing was heard.", bundle: .module).font(.headline)
      Text(
        "Speak closer to the microphone, or check the input chosen in System Settings › Sound.",
        bundle: .module
      )
      .fixedSize(horizontal: false, vertical: true)
    case .transcriptionFailed:
      Text("What you said could not be transcribed.", bundle: .module).font(.headline)
      Text(
        """
        Try again. If it keeps failing, delete the model in Settings › Dictation and download it \
        again.
        """,
        bundle: .module
      )
      .fixedSize(horizontal: false, vertical: true)
    }
  }
}

/// A text view held without keeping it: the composer's may be gone when the text is heard.
@MainActor
final class WeakTextView {
  weak var view: NSTextView?

  init(_ view: NSTextView?) {
    self.view = view
  }
}

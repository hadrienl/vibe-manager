import AppKit
import SwiftUI
import VibeApplication
import VibeDomain

/// The symbols, the colours and the project's icon a session may wear: the New Session draft's
/// picker, and the Change Icon popover's (#183).
struct SessionAppearancePicker: View {
  /// The project's icon, when there is one to offer; its image may still be on its way.
  struct ProjectIconOffer {
    let image: NSImage?
  }

  let appearance: SessionAppearance
  let projectIcon: ProjectIconOffer?
  let usesProjectIcon: Bool
  let pickSymbol: (String) -> Void
  let pickColor: (String) -> Void
  let useProjectIcon: () -> Void
  var issues: [SessionDraftIssue] = []
  var caption: Text?

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      Text("Appearance", bundle: .module, comment: "The symbol and colour of the session.")
        .font(.headline)
      HStack(spacing: 6) {
        if let projectIcon {
          ProjectIconChoice(
            image: projectIcon.image, isSelected: usesProjectIcon, select: useProjectIcon)
        }
        ForEach(SessionAppearanceCatalog.symbolNames, id: \.self) { symbol in
          SymbolChoice(
            symbol: symbol,
            isSelected: !usesProjectIcon && appearance.symbolName == symbol,
            select: { pickSymbol(symbol) }
          )
        }
      }
      HStack(spacing: 6) {
        ForEach(SessionAppearanceCatalog.colorHexValues, id: \.self) { hex in
          ColorChoice(
            hex: hex,
            isSelected: !usesProjectIcon && appearance.colorHex == hex,
            select: { pickColor(hex) }
          )
        }
      }
      ForEach(issues) { issue in
        IssueLabel(issue: issue)
      }
      if let caption {
        caption
          .font(.caption)
          .foregroundStyle(.secondary)
      }
    }
  }
}

/// Change Icon… (#183): the draft's picker over a session that exists. Every choice shows at once
/// on the session's badges; the popover keeps it as it closes, and Escape forgets it.
struct SessionAppearancePopover: View {
  let model: AppModel
  let editor: SessionAppearanceEditor

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      SessionAppearancePicker(
        appearance: editor.current,
        projectIcon: editor.projectIconID.map { .init(image: model.icons.image(for: $0)) },
        usesProjectIcon: editor.usesProjectIcon,
        pickSymbol: editor.pickSymbol,
        pickColor: editor.pickColor,
        useProjectIcon: editor.useProjectIcon
      )
      Divider()
      HStack {
        Button(LocalizedStringResource("Revert to Default Icon", bundle: .module)) {
          editor.revertToDefault()
        }
        .disabled(editor.defaultAppearance == nil || editor.isDefault)
        .help(
          Text(
            "The icon a new session with this name and this folder would get.", bundle: .module)
        )
        .accessibilityIdentifier("session-appearance-revert")
        Spacer()
        Button(LocalizedStringResource("Done", bundle: .module)) {
          model.endAppearanceEditing()
        }
        .keyboardShortcut(.defaultAction)
      }
      .controlSize(.small)
    }
    .padding(16)
    .onExitCommand { model.cancelAppearanceEditing() }
    .accessibilityIdentifier("session-appearance-popover")
  }
}

extension View {
  /// The Change Icon popover, on the badge of the session it edits in this place.
  func sessionAppearancePopover(
    model: AppModel, sessionID: SessionID, place: SessionIdentityEditing.Place
  ) -> some View {
    popover(
      isPresented: Binding(
        get: {
          model.appearanceEditor?.editing
            == SessionIdentityEditing(sessionID: sessionID, place: place)
        },
        set: { isPresented in
          // Closed by a click elsewhere: what was chosen is kept. Escape has already let it go.
          if !isPresented,
            model.appearanceEditor?.editing
              == SessionIdentityEditing(sessionID: sessionID, place: place)
          {
            model.endAppearanceEditing()
          }
        }),
      arrowEdge: .trailing
    ) {
      if let editor = model.appearanceEditor, editor.sessionID == sessionID {
        SessionAppearancePopover(model: model, editor: editor)
      }
    }
  }
}

/// What the symbols of the catalogue are called, for VoiceOver and their help tags: an SF Symbol's
/// own name says nothing to a person.
enum SessionSymbolName {
  static func label(for symbol: String) -> LocalizedStringResource {
    switch symbol {
    case "terminal":
      LocalizedStringResource("Terminal", bundle: .module, comment: "A session's symbol.")
    case "wrench.and.screwdriver":
      LocalizedStringResource("Tools", bundle: .module, comment: "A session's symbol.")
    case "doc.text":
      LocalizedStringResource("Document", bundle: .module, comment: "A session's symbol.")
    case "bolt":
      LocalizedStringResource("Lightning", bundle: .module, comment: "A session's symbol.")
    case "ladybug":
      LocalizedStringResource("Bug", bundle: .module, comment: "A session's symbol.")
    case "flask":
      LocalizedStringResource("Flask", bundle: .module, comment: "A session's symbol.")
    case "shippingbox":
      LocalizedStringResource("Package", bundle: .module, comment: "A session's symbol.")
    case "point.3.connected.trianglepath.dotted":
      LocalizedStringResource("Network", bundle: .module, comment: "A session's symbol.")
    default:
      LocalizedStringResource(stringLiteral: symbol)
    }
  }
}

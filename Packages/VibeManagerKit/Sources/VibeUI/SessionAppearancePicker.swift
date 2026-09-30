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
  /// The symbols and colours the Settings offer (#199).
  let palette: SessionAppearancePalette
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
      SessionAppearanceChoices(
        palette: palette,
        current: usesProjectIcon ? nil : appearance,
        pickSymbol: pickSymbol,
        pickColor: pickColor
      ) {
        if let projectIcon {
          ProjectIconChoice(
            image: projectIcon.image, isSelected: usesProjectIcon, select: useProjectIcon)
        }
      } trailingColors: {
        EmptyView()
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

/// The rows of symbols and colours every picker of a badge shows (#199): the lists of the Settings,
/// then the symbol or colour `current` keeps when they no longer offer it, drawn dashed so that it
/// can be kept — nothing already made is ever changed by the lists.
struct SessionAppearanceChoices<LeadingSymbols: View, TrailingColors: View>: View {
  let palette: SessionAppearancePalette
  /// What is chosen now; `nil` when nothing of the lists is (the project's icon, or no appearance).
  let current: SessionAppearance?
  let pickSymbol: (String) -> Void
  let pickColor: (String) -> Void
  @ViewBuilder let leadingSymbols: LeadingSymbols
  @ViewBuilder let trailingColors: TrailingColors

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      AppearanceChoiceGrid {
        leadingSymbols
        // A symbol of the lists this Mac cannot draw — added on a later macOS — is not offered.
        // The one a session or a template keeps is still shown, marked, so that it can be seen
        // and replaced: an unknown name in a template's file would otherwise go unnoticed.
        ForEach(
          palette.symbolChoices(keeping: current?.symbolName).filter {
            SymbolCatalog.isDrawable($0) || $0 == current?.symbolName
          },
          id: \.self
        ) { symbol in
          SymbolChoice(
            symbol: symbol,
            isSelected: current?.symbolName == symbol,
            isOffered: palette.containsSymbol(symbol),
            select: { pickSymbol(symbol) }
          )
        }
      }
      HStack(alignment: .top, spacing: 6) {
        AppearanceChoiceGrid {
          ForEach(palette.swatchChoices(keeping: current?.colorHex)) { swatch in
            ColorChoice(
              swatch: swatch,
              isSelected: current.map { SessionAppearancePalette.normalizedHex($0.colorHex) }
                == swatch.hex,
              isOffered: palette.containsColor(swatch.hex),
              select: { pickColor(swatch.hex) }
            )
          }
        }
        trailingColors
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
        palette: model.appearancePalette.offered,
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
  /// Its name, or that this Mac cannot draw it — a symbol of a later macOS, or a name that is
  /// none, written in a template's file.
  @MainActor
  static func text(for symbol: String) -> Text {
    guard SymbolCatalog.isDrawable(symbol) else {
      return Text(
        "\(symbol), not drawn by this version of macOS", bundle: .module,
        comment: "Help and VoiceOver: a symbol of the list this Mac cannot draw. Its SF name.")
    }
    return Text(label(for: symbol))
  }

  @MainActor
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
      // Added in the Settings (#199): what macOS itself says of it, else its SF name as words.
      LocalizedStringResource(stringLiteral: SymbolCatalog.systemDescription(of: symbol))
    }
  }
}

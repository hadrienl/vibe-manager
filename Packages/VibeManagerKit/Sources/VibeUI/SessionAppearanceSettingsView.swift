import AppKit
import SwiftUI
import UniformTypeIdentifiers
import VibeApplication
import VibeDomain

/// The Badges tab (#199): the symbols and colours a session may be given, in the order the
/// pickers show them, and what they look like on a badge.
///
/// Nothing here touches a session already made: each keeps its own symbol and colour.
struct SessionAppearanceSettingsView: View {
  let model: SessionAppearancePaletteModel

  @State private var isAddingSymbol = false
  @State private var isAddingSwatch = false
  @State private var pendingReset: ResetTarget?
  /// The chip the keyboard is on: ← and → go to its neighbours, ⌥← and ⌥→ move it, ⌫ removes it.
  @FocusState private var focusedChip: String?

  private enum ResetTarget: Identifiable {
    case symbols, swatches
    var id: Self { self }
  }

  var body: some View {
    let palette = model.palette
    Form {
      Section {
        ChipGrid {
          ForEach(palette.symbols, id: \.self) { symbol in
            SymbolChip(symbol: symbol)
              .paletteChip(
                identifier: symbol, index: palette.symbols.firstIndex(of: symbol) ?? 0,
                count: palette.symbols.count, canRemove: palette.canRemoveSymbol,
                label: SymbolChip.label(symbol),
                focus: $focusedChip,
                step: { offset in
                  focusedChip = Self.neighbour(of: symbol, by: offset, in: palette.symbols)
                },
                move: { offset in model.update { $0.moveSymbol(symbol, by: offset) } },
                takePlace: { dropped in
                  let index = palette.symbols.firstIndex(of: symbol) ?? 0
                  model.update { $0.moveSymbol(dropped, to: index) }
                },
                remove: {
                  let next = Self.survivor(of: symbol, in: palette.symbols)
                  model.update { $0.removeSymbol(symbol) }
                  focusedChip = next
                })
          }
          AddChip(isEnabled: palette.canAddSymbol) { isAddingSymbol = true }
            .popover(isPresented: $isAddingSymbol, arrowEdge: .bottom) {
              SymbolSearch(palette: palette) { symbol in
                model.update { $0.addSymbol(symbol) }
                isAddingSymbol = false
              } cancel: {
                isAddingSymbol = false
              }
            }
            .help(Text("Add a Symbol", bundle: .module))
            .accessibilityLabel(Text("Add a Symbol", bundle: .module))
        }
      } header: {
        sectionHeader(
          Text("Symbols", bundle: .module, comment: "A section of the Badges settings."),
          detail: Text(
            """
            Offered when a session or a template is given its appearance. Drag to reorder, or \
            use ⌥← and ⌥→; ⌫ removes the chip selected.
            """,
            bundle: .module),
          isDefault: palette.symbols == SessionAppearancePalette.default.symbols,
          reset: { pendingReset = .symbols })
      }

      Section {
        ChipGrid {
          ForEach(palette.swatches) { swatch in
            SwatchChip(swatch: swatch)
              .paletteChip(
                identifier: swatch.hex,
                index: palette.swatches.firstIndex(of: swatch) ?? 0,
                count: palette.swatches.count, canRemove: palette.canRemoveSwatch,
                label: SwatchChip.label(swatch),
                focus: $focusedChip,
                step: { offset in
                  focusedChip = Self.neighbour(
                    of: swatch.hex, by: offset, in: palette.colorHexValues)
                },
                move: { offset in model.update { $0.moveSwatch(swatch.hex, by: offset) } },
                takePlace: { dropped in
                  let index = palette.swatches.firstIndex(of: swatch) ?? 0
                  model.update { $0.moveSwatch(dropped, to: index) }
                },
                remove: {
                  let next = Self.survivor(of: swatch.hex, in: palette.colorHexValues)
                  model.update { $0.removeSwatch(swatch.hex) }
                  focusedChip = next
                })
          }
          AddChip(isEnabled: palette.canAddSwatch) { isAddingSwatch = true }
            // A sheet, not a popover: the colour panel is a window of its own, and a click in it
            // would close a popover and lose what was typed.
            .sheet(isPresented: $isAddingSwatch) {
              SwatchEditor(palette: palette) { swatch in
                model.update { $0.addSwatch(swatch) }
                isAddingSwatch = false
              } cancel: {
                isAddingSwatch = false
              }
            }
            .help(Text("Add a Colour", bundle: .module))
            .accessibilityLabel(Text("Add a Colour", bundle: .module))
        }
      } header: {
        sectionHeader(
          Text("Colours", bundle: .module, comment: "A section of the Badges settings."),
          detail: Text(
            "The symbol is drawn in white: a colour is only accepted if it can be read on it.",
            bundle: .module),
          isDefault: palette.swatches == SessionAppearancePalette.default.swatches,
          reset: { pendingReset = .swatches })
      }

      Section {
        HStack(spacing: 12) {
          BadgePreview(palette: palette, scheme: .light)
          BadgePreview(palette: palette, scheme: .dark)
        }
      } header: {
        Text("Preview", bundle: .module, comment: "A section of the Badges settings.")
      } footer: {
        Text(
          "Sessions already made keep their symbol and colour, even one no longer in these lists.",
          bundle: .module
        )
        .font(.caption)
        .foregroundStyle(.secondary)
      }
    }
    .formStyle(.grouped)
    .frame(width: SettingsView.formWidth)
    .frame(minHeight: 560)
    .confirmationDialog(
      resetTitle, isPresented: isResetting, titleVisibility: .visible, presenting: pendingReset
    ) { target in
      Button(role: .destructive) {
        switch target {
        case .symbols: model.update { $0.restoreDefaultSymbols() }
        case .swatches: model.update { $0.restoreDefaultSwatches() }
        }
      } label: {
        Text("Restore Defaults", bundle: .module)
      }
    } message: { _ in
      Text("Your additions and your order are lost.", bundle: .module)
    }
  }

  /// The chip `offset` places away, stopping at either end.
  static func neighbour(of identifier: String, by offset: Int, in list: [String]) -> String? {
    guard let index = list.firstIndex(of: identifier) else { return nil }
    return list[min(max(index + offset, 0), list.count - 1)]
  }

  /// Where the keyboard goes once `identifier` is removed: the next chip, or the previous one at
  /// the end. Nowhere when it is the last one, which is not removed.
  static func survivor(of identifier: String, in list: [String]) -> String? {
    guard list.count > 1, let index = list.firstIndex(of: identifier) else { return identifier }
    return index + 1 < list.count ? list[index + 1] : list[index - 1]
  }

  private var isResetting: Binding<Bool> {
    Binding(get: { pendingReset != nil }, set: { if !$0 { pendingReset = nil } })
  }

  private var resetTitle: Text {
    switch pendingReset {
    case .swatches:
      Text("Restore the shipped colours?", bundle: .module)
    default:
      Text("Restore the shipped symbols?", bundle: .module)
    }
  }

  private func sectionHeader(
    _ title: Text, detail: Text, isDefault: Bool, reset: @escaping () -> Void
  ) -> some View {
    HStack(alignment: .firstTextBaseline) {
      VStack(alignment: .leading, spacing: 2) {
        title
        detail
          .font(.caption)
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
      }
      Spacer()
      Button(action: reset) {
        Text("Default", bundle: .module, comment: "Restores the shipped list of the section.")
      }
      .controlSize(.small)
      .disabled(isDefault)
    }
  }
}

// MARK: - Chips

/// Chips that wrap: the lists may hold forty-eight.
private struct ChipGrid<Content: View>: View {
  @ViewBuilder let content: Content

  var body: some View {
    LazyVGrid(
      columns: [GridItem(.adaptive(minimum: 36, maximum: 36), spacing: 8)],
      alignment: .leading, spacing: 8
    ) {
      content
    }
    .padding(.vertical, 4)
  }
}

private struct SymbolChip: View {
  let symbol: String

  var body: some View {
    // Added on a later macOS: kept in the list, but not drawn by this one — nor offered by the
    // pickers. Shown so that it can still be seen, moved and removed.
    Image(systemName: SymbolCatalog.isDrawable(symbol) ? symbol : "questionmark.square.dashed")
      .font(.system(size: 15))
      .foregroundStyle(SymbolCatalog.isDrawable(symbol) ? .primary : .tertiary)
      .frame(width: 36, height: 36)
      .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
  }

  @MainActor
  static func label(_ symbol: String) -> Text {
    guard SymbolCatalog.isDrawable(symbol) else {
      return Text(
        "\(symbol), not drawn by this version of macOS", bundle: .module,
        comment: "Help and VoiceOver: a symbol of the list this Mac cannot draw. Its SF name.")
    }
    return Text(SessionSymbolName.label(for: symbol))
  }
}

private struct SwatchChip: View {
  let swatch: SessionAppearancePalette.Swatch

  var body: some View {
    RoundedRectangle(cornerRadius: 8)
      .fill(Color(sessionHex: swatch.hex))
      .frame(width: 36, height: 36)
      .overlay {
        Image(systemName: "terminal")
          .font(.system(size: 14, weight: .medium))
          .foregroundStyle(.white)
      }
  }

  static func label(_ swatch: SessionAppearancePalette.Swatch) -> Text {
    // The name first, then the hex: two colours may be given the same name.
    if let name = swatch.displayName { return Text(verbatim: "\(name) (\(swatch.hex))") }
    return Text(verbatim: swatch.hex)
  }
}

private struct AddChip: View {
  let isEnabled: Bool
  let action: () -> Void

  var body: some View {
    Button(action: action) {
      Image(systemName: "plus")
        .font(.system(size: 14, weight: .medium))
        .frame(width: 36, height: 36)
        .overlay(
          RoundedRectangle(cornerRadius: 8)
            .strokeBorder(Color(nsColor: .separatorColor), style: StrokeStyle(dash: [3, 2]))
        )
        .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .disabled(!isEnabled)
  }
}

extension View {
  /// A chip of one of the lists: dragged onto another to take its place, moved and removed from
  /// its menu or with VoiceOver's actions, the last one never removed.
  fileprivate func paletteChip(
    identifier: String, index: Int, count: Int, canRemove: Bool, label: Text,
    focus: FocusState<String?>.Binding, step: @escaping (Int) -> Void,
    move: @escaping (Int) -> Void, takePlace: @escaping (String) -> Void,
    remove: @escaping () -> Void
  ) -> some View {
    self
      .overlay {
        RoundedRectangle(cornerRadius: 8)
          .strokeBorder(Color.accentColor, lineWidth: 2)
          .opacity(focus.wrappedValue == identifier ? 1 : 0)
      }
      .help(label)
      .focusable()
      .focused(focus, equals: identifier)
      .focusEffectDisabled()
      .onKeyPress(keys: [.leftArrow, .rightArrow], phases: .down) { press in
        let offset = press.key == .leftArrow ? -1 : 1
        if press.modifiers.contains(.option) { move(offset) } else { step(offset) }
        return .handled
      }
      .onDeleteCommand {
        // The last one stays: a picker with nothing to offer would have no way back.
        if canRemove { remove() } else { NSSound.beep() }
      }
      .simultaneousGesture(TapGesture().onEnded { focus.wrappedValue = identifier })
      .draggable(identifier)
      .dropDestination(for: String.self) { items, _ in
        guard let dropped = items.first, dropped != identifier else { return false }
        takePlace(dropped)
        return true
      }
      .contextMenu {
        Button {
          move(-1)
        } label: {
          Text("Move Left", bundle: .module)
        }
        .disabled(index == 0)
        Button {
          move(1)
        } label: {
          Text("Move Right", bundle: .module)
        }
        .disabled(index >= count - 1)
        Divider()
        Button(role: .destructive, action: remove) {
          Text("Remove", bundle: .module)
        }
        .disabled(!canRemove)
      }
      .accessibilityElement(children: .ignore)
      .accessibilityLabel(label)
      .accessibilityAction(named: Text("Move Left", bundle: .module)) { move(-1) }
      .accessibilityAction(named: Text("Move Right", bundle: .module)) { move(1) }
      .accessibilityAction(named: Text("Remove", bundle: .module)) {
        if canRemove { remove() } else { NSSound.beep() }
      }
  }
}

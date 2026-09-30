import AppKit
import SwiftUI
import VibeDomain

/// A few sessions as the sidebar would show them, on a light or a dark window, with the lists as
/// they are: the names give each its symbol and colour, the way a new session gets them.
struct BadgePreview: View {
  let palette: SessionAppearancePalette
  let scheme: ColorScheme

  private static let names = [
    "Refactor the API", "Fix the CI", "Release notes", "Speed up search",
  ]

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      ForEach(Self.names, id: \.self) { name in
        HStack(spacing: 8) {
          SessionBadge(appearance: palette.derived(forName: name), size: 22)
          Text(verbatim: name)
            .font(.callout)
            .lineLimit(1)
        }
      }
    }
    .padding(12)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(
      scheme == .dark ? Color(white: 0.16) : Color(white: 0.97),
      in: RoundedRectangle(cornerRadius: 8)
    )
    .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.separator))
    .environment(\.colorScheme, scheme)
    .accessibilityElement(children: .combine)
  }
}

// MARK: - Adding a symbol

/// Looks for an SF Symbol among a list of the useful ones, or takes the exact name of any other.
struct SymbolSearch: View {
  let palette: SessionAppearancePalette
  let add: (String) -> Void
  let cancel: () -> Void

  @State private var query = ""
  @State private var chosen: String?

  var body: some View {
    let results = SymbolCatalog.search(query, excluding: palette)
    VStack(alignment: .leading, spacing: 10) {
      Text("Add a Symbol", bundle: .module)
        .font(.headline)
      TextField(text: $query) {
        Text("Search symbols", bundle: .module)
      }
      .textFieldStyle(.roundedBorder)
      ScrollView {
        LazyVGrid(
          columns: Array(repeating: GridItem(.fixed(30), spacing: 6), count: 9), spacing: 6
        ) {
          ForEach(results, id: \.self) { symbol in
            Button {
              chosen = symbol
            } label: {
              Image(systemName: symbol)
                .frame(width: 30, height: 30)
                .background(
                  chosen == symbol ? Color.accentColor.opacity(0.25) : Color.clear,
                  in: RoundedRectangle(cornerRadius: 6)
                )
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(Text(verbatim: symbol))
            .accessibilityLabel(Text(SessionSymbolName.label(for: symbol)))
            .accessibilityAddTraits(chosen == symbol ? [.isSelected] : [])
          }
        }
      }
      .frame(height: 170)
      Group {
        if let chosen {
          Text(verbatim: chosen)
        } else if results.isEmpty {
          Text("No symbol of that name.", bundle: .module)
        } else {
          Text("Pick a symbol, or type the exact name of one.", bundle: .module)
        }
      }
      .font(.caption)
      .foregroundStyle(.secondary)
      HStack {
        Spacer()
        Button(action: cancel) {
          Text("Cancel", bundle: .module)
        }
        .keyboardShortcut(.cancelAction)
        Button {
          if let chosen { add(chosen) }
        } label: {
          Text("Add", bundle: .module)
        }
        .keyboardShortcut(.defaultAction)
        .disabled(chosen == nil)
      }
    }
    .padding(16)
    .frame(width: 340)
    .onChange(of: query) {
      // A name typed exactly is chosen at once; anything else waits for a click.
      let typed = query.trimmingCharacters(in: .whitespaces)
      chosen = SymbolCatalog.exists(typed) && !palette.containsSymbol(typed) ? typed : nil
    }
  }
}

/// The SF Symbols offered by the search. macOS has no public list of them: these are the ones
/// that suit a kind of work, and any other can still be typed by its exact name.
enum SymbolCatalog {
  static let names = [
    "terminal", "apple.terminal", "chevron.left.forwardslash.chevron.right",
    "curlybraces", "function", "number", "at", "command", "keyboard",
    "wrench.and.screwdriver", "hammer", "screwdriver", "gearshape", "gearshape.2",
    "slider.horizontal.3", "doc", "doc.text", "doc.richtext", "doc.on.doc", "book",
    "book.closed", "books.vertical", "text.book.closed", "newspaper", "note.text", "list.bullet",
    "checklist", "list.bullet.clipboard", "folder", "archivebox", "tray", "tray.full",
    "externaldrive", "internaldrive", "server.rack", "cpu", "memorychip", "desktopcomputer",
    "laptopcomputer", "iphone", "ipad", "applewatch", "display", "network", "globe",
    "network.badge.shield.half.filled", "cloud", "icloud", "antenna.radiowaves.left.and.right",
    "wifi", "bolt", "bolt.fill", "flame", "sparkles", "wand.and.stars", "star", "heart",
    "flag", "bookmark", "tag", "pin", "mappin", "map", "location", "paperplane", "envelope",
    "bubble.left", "bubble.left.and.bubble.right", "megaphone", "bell", "exclamationmark.triangle",
    "questionmark.circle", "info.circle", "checkmark.seal", "xmark.octagon", "ladybug", "ant",
    "leaf", "tree", "flask", "testtube.2", "atom", "brain", "brain.head.profile", "eye",
    "magnifyingglass", "scope", "binoculars", "lightbulb", "graduationcap", "puzzlepiece",
    "shippingbox", "cube", "cube.transparent", "square.stack.3d.up", "square.grid.2x2",
    "rectangle.3.group", "chart.bar", "chart.line.uptrend.xyaxis", "chart.pie", "gauge",
    "speedometer", "timer", "clock", "calendar", "hourglass",
    "point.3.connected.trianglepath.dotted",
    "arrow.triangle.branch", "arrow.triangle.merge", "arrow.triangle.pull",
    "arrow.triangle.2.circlepath", "arrow.clockwise", "arrow.up.arrow.down", "shuffle", "repeat",
    "link", "paperclip", "lock", "lock.open", "key", "shield", "checkmark.shield", "person",
    "person.2", "person.3", "figure.walk", "hand.raised", "hand.thumbsup", "paintbrush",
    "paintpalette", "pencil", "highlighter", "scissors", "ruler", "photo", "camera",
    "video", "film", "music.note", "waveform", "mic", "speaker.wave.2", "headphones",
    "gamecontroller", "car", "airplane", "tram", "bicycle", "sailboat", "house", "building.2",
    "storefront", "cart", "creditcard", "banknote", "dollarsign.circle", "eurosign.circle",
    "gift", "trophy", "rosette", "crown", "moon", "sun.max", "cloud.sun", "snowflake", "drop",
    "tornado", "hare", "tortoise", "bird", "fish", "pawprint", "carrot", "cup.and.saucer",
    "fork.knife", "cross.case", "stethoscope", "pills", "bandage", "dumbbell", "sportscourt",
    "rocket", "airplane.departure", "target", "dice", "suit.spade", "infinity", "sum",
    "percent", "x.squareroot", "tablecells", "table", "externaldrive.connected.to.line.below",
    "cylinder", "cylinder.split.1x2", "square.and.arrow.up", "square.and.arrow.down",
    "tray.and.arrow.down", "arrow.down.doc", "doc.badge.gearshape", "folder.badge.gearshape",
    "hammer.circle", "wrench.adjustable", "bandage.fill", "stethoscope.circle",
  ]

  /// Words a kind of work is looked for by, when the symbol's name does not hold them. In English,
  /// as the names are.
  static let keywords: [String: [String]] = [
    "terminal": ["shell", "console", "cli", "command"],
    "apple.terminal": ["shell", "console", "cli"],
    "chevron.left.forwardslash.chevron.right": ["code", "html", "dev", "web"],
    "curlybraces": ["code", "json", "dev"],
    "function": ["code", "math", "lambda"],
    "wrench.and.screwdriver": ["tools", "fix", "repair", "maintenance"],
    "hammer": ["build", "tools", "fix"],
    "gearshape": ["settings", "config", "preferences"],
    "gearshape.2": ["settings", "config", "automation"],
    "doc.text": ["document", "docs", "spec", "readme"],
    "book": ["docs", "documentation", "guide", "manual"],
    "checklist": ["todo", "tasks", "review", "test"],
    "list.bullet.clipboard": ["todo", "tasks", "plan"],
    "server.rack": ["backend", "infra", "ops", "database"],
    "cylinder": ["database", "db", "storage", "sql"],
    "cylinder.split.1x2": ["database", "db", "migration"],
    "externaldrive": ["storage", "backup", "disk"],
    "cpu": ["performance", "hardware", "chip"],
    "globe": ["web", "internet", "i18n", "translation", "world"],
    "network": ["api", "graph", "connections"],
    "cloud": ["deploy", "infra", "aws", "server"],
    "bolt": ["fast", "performance", "power", "quick"],
    "flame": ["hotfix", "urgent", "fire", "performance"],
    "sparkles": ["ai", "magic", "new", "clean"],
    "wand.and.stars": ["ai", "magic", "refactor"],
    "exclamationmark.triangle": ["warning", "incident", "error", "alert"],
    "xmark.octagon": ["error", "stop", "failure"],
    "ladybug": ["bug", "debug", "fix", "issue"],
    "ant": ["bug", "debug", "insect"],
    "flask": ["test", "experiment", "lab", "spike"],
    "testtube.2": ["test", "experiment", "lab"],
    "brain": ["ai", "ml", "idea", "think"],
    "magnifyingglass": ["search", "find", "investigate", "review"],
    "lightbulb": ["idea", "spike", "prototype"],
    "shippingbox": ["package", "release", "deploy", "ship", "dependency"],
    "cube": ["model", "3d", "package", "module"],
    "chart.bar": ["stats", "analytics", "metrics", "data"],
    "chart.line.uptrend.xyaxis": ["growth", "analytics", "metrics"],
    "gauge": ["performance", "metrics", "monitoring"],
    "speedometer": ["performance", "speed", "benchmark"],
    "timer": ["cron", "schedule", "time"],
    "calendar": ["schedule", "planning", "date"],
    "arrow.triangle.branch": ["git", "branch", "fork"],
    "arrow.triangle.merge": ["git", "merge", "pull request"],
    "arrow.triangle.pull": ["git", "pull request", "review"],
    "arrow.triangle.2.circlepath": ["sync", "refresh", "ci", "loop"],
    "lock": ["security", "auth", "private"],
    "key": ["auth", "secret", "password", "security"],
    "shield": ["security", "protection"],
    "checkmark.shield": ["security", "audit", "compliance"],
    "person": ["user", "account", "profile"],
    "person.2": ["team", "users", "pair"],
    "paintbrush": ["design", "ui", "style", "css"],
    "paintpalette": ["design", "ui", "colour", "color", "theme"],
    "photo": ["image", "picture", "media"],
    "rocket": ["launch", "deploy", "release", "ship"],
    "airplane.departure": ["deploy", "launch", "release"],
    "paperplane": ["send", "deploy", "message", "email"],
    "envelope": ["email", "mail", "message"],
    "bubble.left.and.bubble.right": ["chat", "conversation", "discussion"],
    "megaphone": ["announcement", "marketing", "release notes"],
    "bell": ["notification", "alert"],
    "cart": ["shop", "ecommerce", "checkout"],
    "creditcard": ["payment", "billing", "stripe"],
    "house": ["home", "landing", "main"],
    "target": ["goal", "focus", "objective"],
    "trophy": ["win", "goal", "achievement"],
    "tablecells": ["spreadsheet", "table", "data", "csv"],
  ]

  /// The symbols of the list this Mac draws, less those already offered, matching every word of
  /// `query`. An exact name typed that the list does not hold comes first.
  static func search(_ query: String, excluding palette: SessionAppearancePalette) -> [String] {
    let typed = query.trimmingCharacters(in: .whitespaces).lowercased()
    let words = typed.split(whereSeparator: { $0 == " " || $0 == "." }).map(String.init)
    var results = available.filter { name in
      !palette.containsSymbol(name)
        && words.allSatisfy { word in
          name.contains(word) || keywords[name, default: []].contains { $0.hasPrefix(word) }
        }
    }
    if !typed.isEmpty, !results.contains(typed), exists(typed), !palette.containsSymbol(typed) {
      results.insert(typed, at: 0)
    }
    return results
  }

  static func exists(_ name: String) -> Bool {
    !name.isEmpty && NSImage(systemSymbolName: name, accessibilityDescription: nil) != nil
  }

  @MainActor private static var drawable: [String: Bool] = [:]
  @MainActor private static var descriptions: [String: String] = [:]

  /// What macOS says of a symbol — "send" for `paperplane.circle` — asked once per name; its SF
  /// name read as words when it says nothing, or does not know it.
  @MainActor
  static func systemDescription(of name: String) -> String {
    if let known = descriptions[name] { return known }
    let said = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
      .accessibilityDescription
    let answer =
      said.flatMap { $0.isEmpty ? nil : $0 } ?? name.replacingOccurrences(of: ".", with: " ")
    descriptions[name] = answer
    return answer
  }

  /// Whether this Mac draws `name`, asked once per name: the pickers ask at every redraw.
  @MainActor
  static func isDrawable(_ name: String) -> Bool {
    if let known = drawable[name] { return known }
    let answer = exists(name)
    drawable[name] = answer
    return answer
  }

  /// Read once: a name this version of macOS does not know is never offered.
  private static let available: [String] = {
    var seen: Set<String> = []
    return names.filter { seen.insert($0).inserted && exists($0) }
  }()
}

// MARK: - Adding a colour

/// Picks a colour, names it, and says whether the white symbol can be read on it — offering the
/// closest colour that can when it cannot.
struct SwatchEditor: View {
  let palette: SessionAppearancePalette
  let add: (SessionAppearancePalette.Swatch) -> Void
  let cancel: () -> Void

  @State private var hex = "#D4A017"
  @State private var name = ""

  var body: some View {
    let normalized = SessionAppearancePalette.normalizedHex(hex)
    let contrast = normalized.flatMap(SessionAppearancePalette.glyphContrast(on:))
    let isLegible = normalized.map(SessionAppearancePalette.isLegible) ?? false
    let isTaken = normalized.map(palette.containsColor) ?? false
    VStack(alignment: .leading, spacing: 12) {
      Text("Add a Colour", bundle: .module)
        .font(.headline)
      HStack(spacing: 10) {
        ColorPicker(selection: colorBinding, supportsOpacity: false) {
          Text("Colour", bundle: .module)
        }
        .labelsHidden()
        TextField(text: $hex) {
          Text(verbatim: "#RRGGBB")
        }
        .textFieldStyle(.roundedBorder)
        .font(.body.monospaced())
        .frame(width: 100)
        SessionBadge(
          appearance: SessionAppearance(symbolName: "terminal", colorHex: normalized ?? "#8E8E96"),
          size: 30)
      }
      TextField(text: $name) {
        Text("Name (optional)", bundle: .module)
      }
      .textFieldStyle(.roundedBorder)
      .onChange(of: name) {
        let limit = SessionAppearancePalette.Swatch.maximumNameLength
        if name.count > limit { name = String(name.prefix(limit)) }
      }

      Group {
        if normalized == nil {
          Label {
            Text("Type a colour as #RRGGBB.", bundle: .module)
          } icon: {
            Image(systemName: "exclamationmark.triangle")
          }
        } else if isTaken {
          Label {
            Text("This colour is already in the list.", bundle: .module)
          } icon: {
            Image(systemName: "exclamationmark.triangle")
          }
        } else if let contrast {
          contrastLine(contrast, isLegible: isLegible)
        }
      }
      .font(.callout)
      .foregroundStyle(isLegible && !isTaken ? Color.secondary : Color.orange)

      if let normalized, !isLegible,
        let suggestion = SessionAppearancePalette.legibleVariant(of: normalized)
      {
        HStack(spacing: 8) {
          SessionBadge(
            appearance: SessionAppearance(symbolName: "terminal", colorHex: suggestion), size: 22)
          Text("Closest that can be read: \(suggestion)", bundle: .module)
            .font(.callout)
          Button {
            hex = suggestion
          } label: {
            Text("Use", bundle: .module, comment: "Takes the suggested colour.")
          }
          .controlSize(.small)
        }
      }

      HStack {
        Spacer()
        Button(action: cancel) {
          Text("Cancel", bundle: .module)
        }
        .keyboardShortcut(.cancelAction)
        Button {
          if let normalized { add(SessionAppearancePalette.Swatch(hex: normalized, name: name)) }
        } label: {
          Text("Add", bundle: .module)
        }
        .keyboardShortcut(.defaultAction)
        .disabled(normalized == nil || !isLegible || isTaken)
      }
    }
    .padding(16)
    .frame(width: 340)
  }

  private func contrastLine(_ contrast: Double, isLegible: Bool) -> some View {
    // Rounded down: 2.96 said "3.0:1, under 3:1" would contradict itself.
    let ratio = ((contrast * 10).rounded(.down) / 10).formatted(
      .number.precision(.fractionLength(1)))
    return Label {
      if isLegible {
        Text("The white symbol can be read: \(ratio):1.", bundle: .module)
      } else {
        Text("The white symbol cannot be read: \(ratio):1, under 3:1.", bundle: .module)
      }
    } icon: {
      Image(systemName: isLegible ? "checkmark.circle" : "exclamationmark.triangle")
    }
  }

  private var colorBinding: Binding<Color> {
    Binding(
      get: { Color(sessionHex: SessionAppearancePalette.normalizedHex(hex) ?? "#8E8E96") },
      set: { color in
        guard let srgb = NSColor(color).usingColorSpace(.sRGB) else { return }
        func byte(_ value: CGFloat) -> Int { Int((min(max(value, 0), 1) * 255).rounded()) }
        hex = String(
          format: "#%02X%02X%02X", byte(srgb.redComponent), byte(srgb.greenComponent),
          byte(srgb.blueComponent))
      })
  }
}

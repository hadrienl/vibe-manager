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

/// The SF Symbols offered by the search: first a few that suit a kind of work, then every other
/// this Mac has (`SystemSymbols`). Any symbol can still be typed by its exact name.
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
          name.contains(word)
            || keywords[name, default: []].contains { $0.hasPrefix(word) }
            || system.keywords[name, default: []].contains { $0.hasPrefix(word) }
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
  /// Read once: the chosen ones first, then the rest of the system's, in its own order. Without
  /// the system's list, only the chosen ones this version of macOS draws.
  private static let available: [String] = {
    var seen: Set<String> = []
    let chosen = names.filter { seen.insert($0).inserted && exists($0) }
    return chosen + system.names.filter { seen.insert($0).inserted }
  }()

  private static let system = SystemSymbols.installed ?? SystemSymbols(names: [], keywords: [:])
}

/// Every SF Symbol this Mac has, and the words the system finds each by, as macOS keeps them for
/// itself in CoreGlyphs. Not a public interface: read with care, and absent — `nil` — as soon as
/// anything is not as expected, the search then offering its own list.
///
/// Left out: the variants of a symbol for a script (`character.book.closed.ar`, `.hi`, `.rtl`…),
/// which the system picks by itself, and the symbols Apple restricts to its own products.
struct SystemSymbols: Sendable {
  let names: [String]
  let keywords: [String: [String]]

  static let installed = SystemSymbols(
    resources: URL(
      fileURLWithPath: "/System/Library/CoreServices/CoreGlyphs.bundle/Contents/Resources"))

  /// The endings of a symbol's variants for a script or a writing direction.
  static let scriptVariants: Set<String> = [
    "ar", "bn", "cy", "dv", "el", "fa", "gu", "he", "hi", "ja", "km", "kn", "ko", "lo", "ml",
    "mni", "mr", "my", "or", "pa", "rtl", "sat", "si", "ta", "te", "th", "ur", "zh",
  ]

  init(names: [String], keywords: [String: [String]]) {
    self.names = names
    self.keywords = keywords
  }

  init?(resources: URL) {
    func plist(_ name: String) -> Any? {
      guard let data = try? Data(contentsOf: resources.appendingPathComponent(name)) else {
        return nil
      }
      return try? PropertyListSerialization.propertyList(from: data, format: nil)
    }
    guard let order = plist("symbol_order.plist") as? [String], !order.isEmpty else { return nil }
    let restricted = (plist("symbol_restrictions.strings") as? [String: Any]).map { Set($0.keys) }
    let all = Set(order)
    names = order.filter { name in
      if restricted?.contains(name) == true { return false }
      guard let dot = name.lastIndex(of: ".") else { return true }
      let ending = String(name[name.index(after: dot)...])
      return !(Self.scriptVariants.contains(ending) && all.contains(String(name[..<dot])))
    }
    keywords = (plist("symbol_search.plist") as? [String: [String]]) ?? [:]
  }
}

// MARK: - Adding a colour

/// Picks a colour among shades ready to use, or by hue and brightness, or by its hex; names it, and
/// says whether the white symbol can be read on it — offering the closest colour that can when it
/// cannot. Everything is in the popover: the system's colour panel is a window of its own, and a
/// click in it would close the popover and lose what was chosen.
struct SwatchEditor: View {
  let palette: SessionAppearancePalette
  let add: (SessionAppearancePalette.Swatch) -> Void
  let cancel: () -> Void

  @State private var hex: String
  @State private var name = ""
  /// Kept apart from `hex`: at no saturation or no brightness a colour has no hue, and the sliders
  /// must not jump back to red.
  @State private var hue: Double
  @State private var saturation: Double
  @State private var brightness: Double

  init(
    palette: SessionAppearancePalette,
    add: @escaping (SessionAppearancePalette.Swatch) -> Void,
    cancel: @escaping () -> Void
  ) {
    self.palette = palette
    self.add = add
    self.cancel = cancel
    let first =
      SessionAppearancePalette.suggestedColors.joined().first { !palette.containsColor($0) }
      ?? "#0B63E5"
    let (hue, saturation, brightness) = SessionAppearancePalette.hsb(of: first) ?? (0.6, 0.8, 0.8)
    _hex = State(initialValue: first)
    _hue = State(initialValue: hue)
    _saturation = State(initialValue: saturation)
    _brightness = State(initialValue: brightness)
  }

  var body: some View {
    let normalized = SessionAppearancePalette.normalizedHex(hex)
    let contrast = normalized.flatMap(SessionAppearancePalette.glyphContrast(on:))
    let isLegible = normalized.map(SessionAppearancePalette.isLegible) ?? false
    let isTaken = normalized.map(palette.containsColor) ?? false
    VStack(alignment: .leading, spacing: 12) {
      Text("Add a Colour", bundle: .module)
        .font(.headline)

      suggestions(selected: normalized)

      HStack(spacing: 14) {
        ColorWheel(
          hue: $hue, saturation: $saturation, brightness: brightness,
          changed: { hex = currentHex }
        )
        .frame(width: 132, height: 132)
        VStack(alignment: .leading, spacing: 4) {
          Text(
            "Brightness", bundle: .module,
            comment: "A slider: the brightness of the colour being added."
          )
          .foregroundStyle(.secondary)
          Slider(value: slider(.brightness), in: 0...1)
            .accessibilityLabel(Text("Brightness", bundle: .module))
        }
        .controlSize(.small)
      }

      HStack(spacing: 10) {
        TextField(text: $hex) {
          Text(verbatim: "#RRGGBB")
        }
        .textFieldStyle(.roundedBorder)
        .font(.body.monospaced())
        .frame(width: 100)
        .onChange(of: hex) { follow(hex) }
        SessionBadge(
          appearance: SessionAppearance(symbolName: "terminal", colorHex: normalized ?? "#8E8E96"),
          size: 26)
      }

      TextField(text: $name) {
        Text("Name (optional)", bundle: .module)
      }
      .textFieldStyle(.roundedBorder)
      .onChange(of: name) {
        let limit = SessionAppearancePalette.Swatch.maximumNameLength
        if name.count > limit { name = String(name.prefix(limit)) }
      }

      verdict(normalized: normalized, contrast: contrast, isLegible: isLegible, isTaken: isTaken)

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
    .frame(width: 300)
  }

  /// Shades ready to add, all legible; those already in the list are shown, faded, not offered.
  private func suggestions(selected: String?) -> some View {
    LazyVGrid(
      columns: Array(repeating: GridItem(.fixed(22), spacing: 5), count: 10), spacing: 5
    ) {
      ForEach(SessionAppearancePalette.suggestedColors.joined().map { $0 }, id: \.self) { color in
        let isTaken = palette.containsColor(color)
        Button {
          hex = color
        } label: {
          RoundedRectangle(cornerRadius: 5)
            .fill(Color(sessionHex: color))
            .frame(width: 22, height: 22)
            .overlay(
              RoundedRectangle(cornerRadius: 5)
                .strokeBorder(selected == color ? Color.primary : .clear, lineWidth: 2)
            )
            .opacity(isTaken ? 0.3 : 1)
        }
        .buttonStyle(.plain)
        .disabled(isTaken)
        .help(Text(verbatim: color))
        .accessibilityLabel(Text(verbatim: color))
        .accessibilityAddTraits(selected == color ? [.isSelected] : [])
      }
    }
    .fixedSize()
  }

  @ViewBuilder
  private func verdict(normalized: String?, contrast: Double?, isLegible: Bool, isTaken: Bool)
    -> some View
  {
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
    .fixedSize(horizontal: false, vertical: true)

    if let normalized, !isLegible, !isTaken,
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
  }

  private func contrastLine(_ contrast: Double, isLegible: Bool) -> some View {
    let ratio = Self.ratio(contrast)
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

  /// Rounded down: 2.96 said "3.0:1, under 3:1" would contradict itself.
  private static func ratio(_ contrast: Double) -> String {
    ((contrast * 10).rounded(.down) / 10).formatted(.number.precision(.fractionLength(1)))
  }

  private enum Channel { case hue, brightness }

  private var currentHex: String {
    SessionAppearancePalette.hex(hue: hue, saturation: saturation, brightness: brightness)
  }

  /// A slider moves its channel and writes the colour; the others stay as they were.
  private func slider(_ channel: Channel) -> Binding<Double> {
    Binding(
      get: { channel == .hue ? hue : brightness },
      set: { value in
        if channel == .hue { hue = value } else { brightness = value }
        hex = SessionAppearancePalette.hex(
          hue: hue, saturation: saturation, brightness: brightness)
      })
  }

  /// A colour chosen or typed moves the sliders — but only what it says: a grey keeps the hue.
  private func follow(_ text: String) {
    guard let normalized = SessionAppearancePalette.normalizedHex(text),
      normalized
        != SessionAppearancePalette.hex(hue: hue, saturation: saturation, brightness: brightness),
      let (newHue, newSaturation, newBrightness) = SessionAppearancePalette.hsb(of: normalized)
    else { return }
    if newSaturation > 0, newBrightness > 0 { hue = newHue }
    if newBrightness > 0 { saturation = newSaturation }
    brightness = newBrightness
  }
}

/// Hue around, saturation from the centre out, at the brightness of the slider beside it: drawn
/// here rather than borrowed from the system's colour panel, a window whose clicks would close the
/// popover it serves.
struct ColorWheel: View {
  @Binding var hue: Double
  @Binding var saturation: Double
  let brightness: Double
  /// Told after every move, so that the colour is written from the three channels.
  let changed: () -> Void

  var body: some View {
    GeometryReader { proxy in
      let radius = min(proxy.size.width, proxy.size.height) / 2
      let center = CGPoint(x: proxy.size.width / 2, y: proxy.size.height / 2)
      ZStack {
        Circle()
          .fill(
            AngularGradient(
              colors: (0...36).map { step in
                Color(hue: Double(step) / 36, saturation: 1, brightness: 1)
              },
              center: .center))
        Circle()
          .fill(
            RadialGradient(
              colors: [.white, .white.opacity(0)], center: .center,
              startRadius: 0, endRadius: radius))
        Circle()
          .fill(.black.opacity(1 - brightness))
        Circle()
          .strokeBorder(Color(nsColor: .separatorColor), lineWidth: 1)
        Circle()
          .fill(Color(hue: hue, saturation: saturation, brightness: brightness))
          .frame(width: 14, height: 14)
          .overlay(Circle().strokeBorder(.white, lineWidth: 2))
          .shadow(color: .black.opacity(0.4), radius: 1.5)
          .position(
            x: center.x + cos(hue * 2 * .pi) * saturation * radius,
            y: center.y + sin(hue * 2 * .pi) * saturation * radius)
      }
      .contentShape(Circle())
      .gesture(
        DragGesture(minimumDistance: 0).onChanged { drag in
          let dx = drag.location.x - center.x
          let dy = drag.location.y - center.y
          var angle = atan2(dy, dx) / (2 * .pi)
          if angle < 0 { angle += 1 }
          hue = angle
          saturation = min(hypot(dx, dy) / radius, 1)
          changed()
        })
    }
    .accessibilityElement()
    .accessibilityLabel(Text("Colour wheel", bundle: .module, comment: "VoiceOver: picks a hue."))
    .accessibilityValue(
      Text(verbatim: "\(Int((hue * 360).rounded()))°, \(Int((saturation * 100).rounded())) %")
    )
    .accessibilityAdjustableAction { direction in
      // VoiceOver turns the hue by steps of a twenty-fourth of the wheel.
      let step = direction == .increment ? 1.0 / 24 : -1.0 / 24
      hue = (hue + step + 1).truncatingRemainder(dividingBy: 1)
      changed()
    }
  }
}

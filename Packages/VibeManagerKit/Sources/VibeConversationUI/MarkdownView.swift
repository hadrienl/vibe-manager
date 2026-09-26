import AppKit
import SwiftUI
import VibeApplication

/// A message's Markdown, block by block (#38).
///
/// Each block is its own view, so that a long answer is laid out lazily with the rest of the
/// conversation, and its text is selectable. Selection does not cross blocks — SwiftUI cannot on
/// macOS 14 — which the message's Copy command makes up for.
struct MarkdownView: View {
  let text: String
  @Environment(\.conversationTheme) private var theme
  @Environment(\.conversationAppearance) private var appearance

  var body: some View {
    let blocks = MarkdownCache.shared.blocks(for: text)
    VStack(alignment: .leading, spacing: appearance.density == .compact ? 6 : 10) {
      ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
        MarkdownBlockView(block: block)
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }
}

struct MarkdownBlockView: View {
  let block: MarkdownBlock
  @Environment(\.conversationTheme) private var theme
  @Environment(\.conversationAppearance) private var appearance

  private var size: Double { appearance.textSize.pointSize }

  var body: some View {
    switch block {
    case .heading(let level, let runs):
      let scale = level == 1 ? 1.35 : level == 2 ? 1.2 : 1.08
      Text(MarkdownDocument.attributed(runs, theme: theme, size: size * scale, weight: .bold))
        .foregroundStyle(theme.text.color)
        .textSelection(.enabled)
        .padding(.top, 4)
        .accessibilityAddTraits(.isHeader)
    case .paragraph(let runs):
      Text(MarkdownDocument.attributed(runs, theme: theme, size: size))
        .foregroundStyle(theme.text.color)
        .lineSpacing(size * 0.25)
        .textSelection(.enabled)
        .fixedSize(horizontal: false, vertical: true)
    case .list(let ordered, let start, let items):
      VStack(alignment: .leading, spacing: 4) {
        ForEach(Array(items.enumerated()), id: \.offset) { index, item in
          HStack(alignment: .firstTextBaseline, spacing: 8) {
            marker(ordered: ordered, number: start + index, checkbox: item.checkbox)
            VStack(alignment: .leading, spacing: 4) {
              ForEach(Array(item.blocks.enumerated()), id: \.offset) { _, child in
                MarkdownBlockView(block: child)
              }
            }
          }
        }
      }
    case .quote(let blocks):
      HStack(alignment: .top, spacing: 10) {
        RoundedRectangle(cornerRadius: 1.5)
          .fill(theme.border.color)
          .frame(width: 3)
        VStack(alignment: .leading, spacing: 6) {
          ForEach(Array(blocks.enumerated()), id: \.offset) { _, child in
            MarkdownBlockView(block: child)
          }
        }
        .foregroundStyle(theme.secondaryText.color)
      }
    case .code(let language, let code):
      CodeBlockView(language: language, code: code)
    case .table(let header, let rows):
      MarkdownTableView(header: header, rows: rows)
    case .rule:
      Rectangle().fill(theme.border.color).frame(height: 1).padding(.vertical, 4)
    }
  }

  @ViewBuilder
  private func marker(ordered: Bool, number: Int, checkbox: Bool?) -> some View {
    if let checkbox {
      Image(systemName: checkbox ? "checkmark.square.fill" : "square")
        .foregroundStyle(checkbox ? theme.success.color : theme.secondaryText.color)
        .accessibilityLabel(
          checkbox
            ? Text("Done", bundle: .module) : Text("To do", bundle: .module))
    } else if ordered {
      Text(verbatim: "\(number).")
        .font(theme.messageFont(size: size))
        .foregroundStyle(theme.secondaryText.color)
        .monospacedDigit()
    } else {
      Text(verbatim: "•")
        .font(theme.messageFont(size: size))
        .foregroundStyle(theme.secondaryText.color)
    }
  }
}

struct MarkdownTableView: View {
  let header: [[InlineRun]]
  let rows: [[[InlineRun]]]
  @Environment(\.conversationTheme) private var theme
  @Environment(\.conversationAppearance) private var appearance

  var body: some View {
    let size = appearance.textSize.pointSize * 0.92
    ScrollView(.horizontal, showsIndicators: true) {
      Grid(alignment: .leading, horizontalSpacing: 0, verticalSpacing: 0) {
        GridRow {
          ForEach(Array(header.enumerated()), id: \.offset) { _, cell in
            Text(MarkdownDocument.attributed(cell, theme: theme, size: size, weight: .semibold))
              .padding(.horizontal, 10)
              .padding(.vertical, 6)
          }
        }
        .background(theme.surface.color)
        ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
          Divider().overlay(theme.border.color)
          GridRow {
            ForEach(Array(row.enumerated()), id: \.offset) { _, cell in
              Text(MarkdownDocument.attributed(cell, theme: theme, size: size))
                .textSelection(.enabled)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
            }
          }
        }
      }
      .foregroundStyle(theme.text.color)
    }
    .clipShape(RoundedRectangle(cornerRadius: 8))
    .overlay(RoundedRectangle(cornerRadius: 8).stroke(theme.border.color))
  }
}

/// A block of code: monospaced, coloured by its words, scrolled rather than wrapped unless the
/// user asked, with its language and a Copy button.
struct CodeBlockView: View {
  let language: String?
  let code: String
  @Environment(\.conversationTheme) private var theme
  @Environment(\.conversationAppearance) private var appearance
  @State private var copied = false

  var body: some View {
    let size = appearance.textSize.pointSize * 0.88
    VStack(alignment: .leading, spacing: 0) {
      HStack {
        Text(verbatim: language ?? "")
          .font(theme.interfaceFont(size: 11))
          .foregroundStyle(theme.secondaryText.color)
        Spacer()
        Button {
          NSPasteboard.general.clearContents()
          NSPasteboard.general.setString(code, forType: .string)
          copied = true
        } label: {
          Label {
            copied ? Text("Copied", bundle: .module) : Text("Copy", bundle: .module)
          } icon: {
            Image(systemName: copied ? "checkmark" : "doc.on.doc")
          }
          .font(theme.interfaceFont(size: 11))
        }
        .buttonStyle(.plain)
        .foregroundStyle(theme.secondaryText.color)
        .help(Text("Copy the code", bundle: .module))
      }
      .padding(.horizontal, 12)
      .padding(.vertical, 6)
      Rectangle().fill(theme.border.color).frame(height: 1)
      Group {
        if appearance.wrapsCode {
          highlighted(size: size).fixedSize(horizontal: false, vertical: true)
        } else {
          ScrollView(.horizontal, showsIndicators: true) {
            highlighted(size: size).fixedSize()
          }
        }
      }
      .padding(12)
    }
    .background(theme.codeBackground.color)
    .clipShape(RoundedRectangle(cornerRadius: 10))
    .overlay(RoundedRectangle(cornerRadius: 10).stroke(theme.border.color))
    .onChange(of: code) { copied = false }
  }

  private func highlighted(size: Double) -> some View {
    Text(Self.attributed(code, language: language, theme: theme, size: size))
      .textSelection(.enabled)
      .lineSpacing(2)
      .frame(maxWidth: .infinity, alignment: .leading)
  }

  static func attributed(
    _ code: String, language: String?, theme: ConversationTheme, size: Double
  ) -> AttributedString {
    var result = AttributedString()
    for segment in SyntaxHighlighter.segments(of: code, language: language) {
      var piece = AttributedString(segment.text)
      piece.font = theme.codeFont(size: size)
      piece.foregroundColor = color(for: segment.kind, theme: theme).color
      result += piece
    }
    return result
  }

  static func color(for kind: SyntaxHighlighter.Kind, theme: ConversationTheme) -> ThemeColor {
    switch kind {
    case .plain: return theme.codeText
    case .keyword: return theme.keyword
    case .string: return theme.string
    case .comment, .meta: return theme.comment
    case .number: return theme.number
    case .type: return theme.type
    case .function: return theme.function
    case .added: return theme.addedText
    case .removed: return theme.removedText
    }
  }
}

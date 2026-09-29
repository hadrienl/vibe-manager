import AppKit
import SwiftUI
import VibeApplication

/// A message's Markdown, block by block (#38).
///
/// Its prose — headings, paragraphs, lists and quotes that follow one another — is one text view,
/// selectable from one paragraph to the next (`MarkdownProse`); code blocks and tables are text
/// views of their own, rules plain views, between them. One selection runs across all of them
/// (`MessageSelection`, #189), but not from one message to the next: Copy Message makes up for it.
struct MarkdownView: View {
  let text: String
  @State private var selection = MessageSelection()

  var body: some View {
    MarkdownBlocksView(blocks: MarkdownCache.shared.blocks(for: text), markdown: text)
      .frame(maxWidth: .infinity, alignment: .leading)
      .environment(\.messageSelection, selection)
  }
}

/// Blocks, their prose gathered into text views.
struct MarkdownBlocksView: View {
  let blocks: [MarkdownBlock]
  let markdown: String
  var spacing: Double?
  var secondary = false
  @Environment(\.conversationAppearance) private var appearance
  @Environment(\.conversationTheme) private var theme

  var body: some View {
    VStack(
      alignment: .leading,
      spacing: spacing ?? theme.layout.at(appearance.density).paragraphSpacing
    ) {
      ForEach(Array(MarkdownProse.segments(blocks).enumerated()), id: \.offset) { _, segment in
        switch segment {
        case .prose(let blocks):
          SegmentView(content: .prose(blocks, secondary: secondary), markdown: markdown)
        case .block(let block):
          MarkdownBlockView(block: block, markdown: markdown, secondary: secondary)
        }
      }
    }
  }
}

/// A block that is not only prose: a code block, a table, a rule, or a list or a quote holding one.
struct MarkdownBlockView: View {
  let block: MarkdownBlock
  let markdown: String
  var secondary = false
  @Environment(\.conversationTheme) private var theme
  @Environment(\.conversationAppearance) private var appearance

  private var size: Double { appearance.textSize.pointSize }

  var body: some View {
    switch block {
    case .heading, .paragraph:
      SegmentView(content: .prose([block], secondary: secondary), markdown: markdown)
    case .list(let ordered, let start, let items):
      VStack(alignment: .leading, spacing: 4) {
        ForEach(Array(items.enumerated()), id: \.offset) { index, item in
          HStack(alignment: .firstTextBaseline, spacing: 8) {
            marker(ordered: ordered, number: start + index, checkbox: item.checkbox)
            MarkdownBlocksView(
              blocks: item.blocks, markdown: markdown, spacing: 4, secondary: secondary)
          }
        }
      }
    case .quote(let blocks):
      HStack(alignment: .top, spacing: 10) {
        RoundedRectangle(cornerRadius: 1.5)
          .fill(theme.border.color)
          .frame(width: 3)
        MarkdownBlocksView(blocks: blocks, markdown: markdown, spacing: 6, secondary: true)
      }
    case .code(let language, let code):
      CodeBlockView(language: language, code: code, markdown: markdown)
    case .table(let header, let rows):
      MarkdownTableView(header: header, rows: rows, markdown: markdown)
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
  var markdown: String?
  @Environment(\.conversationTheme) private var theme

  var body: some View {
    ScrollView(.horizontal, showsIndicators: true) {
      SegmentView(content: .table(header: header, rows: rows), markdown: markdown)
        .fixedSize()
    }
    .clipShape(RoundedRectangle(cornerRadius: theme.layout.innerRadius))
    .overlay(RoundedRectangle(cornerRadius: theme.layout.innerRadius).stroke(theme.border.color))
  }
}

/// A block of code: monospaced, coloured by its words, scrolled rather than wrapped unless the
/// user asked, with its language and a Copy button.
struct CodeBlockView: View {
  let language: String?
  let code: String
  var markdown: String?
  @Environment(\.conversationTheme) private var theme
  @Environment(\.conversationAppearance) private var appearance
  @State private var copied = false

  var body: some View {
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
          highlighted().fixedSize(horizontal: false, vertical: true)
        } else {
          ScrollView(.horizontal, showsIndicators: true) {
            highlighted().fixedSize()
          }
        }
      }
      .padding(12)
    }
    .background(theme.codeBackground.color)
    .clipShape(RoundedRectangle(cornerRadius: theme.layout.blockRadius))
    .overlay(RoundedRectangle(cornerRadius: theme.layout.blockRadius).stroke(theme.border.color))
    .onChange(of: code) { copied = false }
  }

  private func highlighted() -> some View {
    SegmentView(content: .code(code, language: language), markdown: markdown)
      .frame(maxWidth: .infinity, alignment: .leading)
  }

  nonisolated static func color(for kind: SyntaxHighlighter.Kind, theme: ConversationTheme)
    -> ThemeColor
  {
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

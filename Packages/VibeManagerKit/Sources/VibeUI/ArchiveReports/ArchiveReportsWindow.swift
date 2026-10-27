import AppKit
import SwiftUI
import UniformTypeIdentifiers
import VibeApplication
import VibeDomain

/// Window ▸ Archive Reports (#408): the batches by day on the left, the report of a batch or of a
/// period on the right, copied or exported in Markdown.
public struct ArchiveReportsWindow: View {
  private let model: AppModel

  public init(model: AppModel) {
    self.model = model
  }

  public var body: some View {
    if let reports = model.archiveReports {
      ArchiveReportsContent(model: model, reports: reports)
        .task { if !reports.loaded { await reports.load() } }
    } else {
      ContentUnavailableView {
        Label {
          Text("Reports are not available", bundle: .module)
        } icon: {
          Image(systemName: "archivebox")
        }
      }
    }
  }
}

private struct ArchiveReportsContent: View {
  let model: AppModel
  @Bindable var reports: ArchiveReportsModel
  @State private var from = Calendar.current.date(byAdding: .day, value: -7, to: Date()) ?? Date()
  @State private var to = Date()
  @State private var exporting: MarkdownDocument?

  var body: some View {
    NavigationSplitView {
      List(selection: $reports.selection) {
        Section {
          ForEach(Self.periods, id: \.self) { period in
            Label {
              Text(Self.name(of: period))
            } icon: {
              Image(systemName: "calendar")
            }
            .tag(ArchiveReportsModel.Selection.period(period))
          }
          Label {
            Text("Chosen Dates", bundle: .module)
          } icon: {
            Image(systemName: "calendar.badge.clock")
          }
          .tag(ArchiveReportsModel.Selection.period(.days(from: from, to: to)))
        } header: {
          Text("Periods", bundle: .module)
        }
        ForEach(reports.days, id: \.day) { day in
          Section {
            ForEach(day.batches) { batch in
              BatchRow(batch: batch)
                .tag(ArchiveReportsModel.Selection.batch(batch.id))
            }
          } header: {
            Text(day.day.formatted(.dateTime.weekday(.wide).day().month(.wide)))
          }
        }
      }
      .navigationSplitViewColumnWidth(min: 220, ideal: 260)
      .safeAreaInset(edge: .bottom) {
        Toggle(isOn: $reports.showsTrials) {
          Text("Show Trial Runs", bundle: .module)
        }
        .toggleStyle(.checkbox)
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
      }
      .overlay {
        if reports.loaded, reports.batches.isEmpty {
          Text("No archive yet", bundle: .module)
            .foregroundStyle(.secondary)
            .padding(.top, 220)
        }
      }
    } detail: {
      detail
    }
    .onChange(of: from) { refreshChosenDates() }
    .onChange(of: to) { refreshChosenDates() }
    .fileExporter(
      isPresented: Binding(get: { exporting != nil }, set: { if !$0 { exporting = nil } }),
      document: exporting, contentType: .markdown, defaultFilename: exporting?.name
    ) { _ in
      exporting = nil
    }
  }

  static let periods: [ArchiveReportPeriod] = [.today, .yesterday, .last7Days, .thisMonth]

  static func name(of period: ArchiveReportPeriod) -> String {
    switch period {
    case .today: String(localized: "Today", bundle: .module, comment: "Archive reports: a period.")
    case .yesterday:
      String(localized: "Yesterday", bundle: .module, comment: "Archive reports: a period.")
    case .last7Days:
      String(localized: "Last 7 Days", bundle: .module, comment: "Archive reports: a period.")
    case .thisMonth:
      String(localized: "This Month", bundle: .module, comment: "Archive reports: a period.")
    case .days:
      String(localized: "Chosen Dates", bundle: .module, comment: "Archive reports: a period.")
    }
  }

  /// The chosen dates follow the pickers while they are what is shown.
  private func refreshChosenDates() {
    if case .period(.days) = reports.selection {
      reports.selection = .period(.days(from: from, to: to))
    }
  }

  @ViewBuilder private var detail: some View {
    if let report = reports.report {
      ArchiveReportView(
        model: model, reports: reports, report: report, title: title,
        chosenDates: isChosenDates ? ($from, $to) : nil,
        export: { markdown in exporting = MarkdownDocument(text: markdown, name: title) })
    } else {
      ContentUnavailableView {
        Label {
          Text("Choose a batch or a period", bundle: .module)
        } icon: {
          Image(systemName: "doc.text.magnifyingglass")
        }
      }
    }
  }

  private var isChosenDates: Bool {
    if case .period(.days) = reports.selection { true } else { false }
  }

  private var title: String {
    switch reports.selection {
    case .batch(let id):
      guard let batch = reports.batch(id) else { return "" }
      return BatchRow.title(of: batch)
    case .period(let period): return Self.name(of: period)
    case nil: return ""
    }
  }
}

/// “19:00 · Evening · 6 sessions”.
private struct BatchRow: View {
  let batch: ArchiveBatch

  var body: some View {
    Label {
      VStack(alignment: .leading, spacing: 2) {
        Text(Self.title(of: batch))
        Text(
          "\(batch.date.formatted(date: .omitted, time: .shortened)) · \(batch.sessions.count) sessions",
          bundle: .module,
          comment: "Archive reports: a batch's time and how many sessions it holds."
        )
        .font(.caption)
        .foregroundStyle(.secondary)
      }
    } icon: {
      Image(systemName: Self.symbol(of: batch))
    }
    .accessibilityElement(children: .combine)
  }

  static func symbol(of batch: ArchiveBatch) -> String {
    switch batch.kind {
    case .rule: "archivebox"
    case .trial: "testtube.2"
    case .selection: "checklist"
    case .manual: "hand.raised"
    }
  }

  static func title(of batch: ArchiveBatch) -> String {
    switch batch.kind {
    case .rule(_, let name): name
    case .trial(_, let name):
      String(
        localized: "\(name) (trial)", bundle: .module,
        comment:
          "Archive reports: a rule's run on trial, which archived nothing. The argument is its name."
      )
    case .selection:
      String(
        localized: "Selection Archived", bundle: .module,
        comment: "Archive reports: sessions the user selected and archived together.")
    case .manual:
      String(
        localized: "Archived by Hand", bundle: .module,
        comment: "Archive reports: the day's batch of sessions the user archived themselves.")
    }
  }
}

/// The report: its totals, the agent's paragraph, then project by project its sessions.
private struct ArchiveReportView: View {
  let model: AppModel
  let reports: ArchiveReportsModel
  let report: ArchiveReport
  let title: String
  let chosenDates: (from: Binding<Date>, to: Binding<Date>)?
  let export: (String) -> Void

  private var text: ArchiveReportText { ArchiveReportText() }

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 16) {
        header
        if let chosenDates {
          HStack {
            DatePicker(selection: chosenDates.from, displayedComponents: .date) {
              Text("From", bundle: .module)
            }
            DatePicker(selection: chosenDates.to, displayedComponents: .date) {
              Text("To", bundle: .module)
            }
          }
          .fixedSize()
        }
        synthesis
        if report.isEmpty {
          Text("Nothing was archived in this period.", bundle: .module)
            .foregroundStyle(.secondary)
        }
        ForEach(report.projects) { project in
          VStack(alignment: .leading, spacing: 10) {
            Text(project.name ?? text.noProject)
              .font(.title3.weight(.semibold))
              .accessibilityAddTraits(.isHeader)
            ForEach(project.sessions) { session in
              SessionReportRow(model: model, session: session, text: text)
            }
          }
        }
        skipped
      }
      .padding(20)
      .frame(maxWidth: .infinity, alignment: .leading)
    }
    .toolbar {
      ToolbarItemGroup {
        Button {
          NSPasteboard.general.clearContents()
          NSPasteboard.general.setString(markdown, forType: .string)
        } label: {
          Label {
            Text("Copy", bundle: .module)
          } icon: {
            Image(systemName: "doc.on.doc")
          }
        }
        .disabled(report.isEmpty)
        Button {
          export(markdown)
        } label: {
          Label {
            Text("Export as Markdown…", bundle: .module)
          } icon: {
            Image(systemName: "square.and.arrow.up")
          }
        }
        .disabled(report.isEmpty)
      }
    }
  }

  private var header: some View {
    VStack(alignment: .leading, spacing: 4) {
      Text(title)
        .font(.title2.weight(.semibold))
        .accessibilityAddTraits(.isHeader)
      if !report.isEmpty {
        Text(text.totals(report.totals))
          .foregroundStyle(.secondary)
      }
    }
  }

  /// The paragraph shown, if there is one.
  private var paragraph: String? {
    if let batch = singleBatch, case .ready(let text, _, _) = batch.synthesis { return text }
    if case .period(let period) = reports.selection,
      case .ready(let text) = reports.periodSyntheses[period]
    {
      return text
    }
    return nil
  }

  private var singleBatch: ArchiveBatch? {
    if case .batch(let id) = reports.selection { reports.batch(id) } else { nil }
  }

  @ViewBuilder private var synthesis: some View {
    if let paragraph {
      Text(paragraph)
        .textSelection(.enabled)
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.5), in: .rect(cornerRadius: 8))
    } else if let batch = singleBatch {
      if reports.synthesizing.contains(batch.id) {
        ProgressView {
          Text("Writing the summary…", bundle: .module)
        }
        .controlSize(.small)
      } else if case .failed = batch.synthesis {
        HStack {
          Text("Summary unavailable", bundle: .module)
            .foregroundStyle(.secondary)
          Button {
            reports.synthesize(batch.id)
          } label: {
            Text("Try Again", bundle: .module)
          }
        }
      } else if batch.offersSynthesis {
        Button {
          reports.synthesize(batch.id)
        } label: {
          Text("Summarize", bundle: .module)
        }
      }
    } else if case .period(let period) = reports.selection, !report.isEmpty {
      switch reports.periodSyntheses[period] {
      case .writing:
        ProgressView {
          Text("Writing the summary…", bundle: .module)
        }
        .controlSize(.small)
      case .failed:
        HStack {
          Text("Summary unavailable", bundle: .module)
            .foregroundStyle(.secondary)
          Button {
            reports.summarize(period)
          } label: {
            Text("Try Again", bundle: .module)
          }
        }
      default:
        Button {
          reports.summarize(period)
        } label: {
          Text("Summarize the Period", bundle: .module)
        }
      }
    }
  }

  @ViewBuilder private var skipped: some View {
    if let batch = singleBatch, !batch.skipped.isEmpty {
      VStack(alignment: .leading, spacing: 4) {
        Text("Left by the rule", bundle: .module)
          .font(.headline)
          .accessibilityAddTraits(.isHeader)
        ForEach(batch.skipped, id: \.sessionID) { skipped in
          Text(verbatim: "\(skipped.name) — \(Self.reason(skipped.reason))")
            .foregroundStyle(.secondary)
        }
      }
    }
  }

  static func reason(_ reason: SkippedSession.Reason) -> String {
    switch reason {
    case .running:
      String(
        localized: "something was running", bundle: .module,
        comment: "Archive reports: why a rule left a session.")
    case .unarchived:
      String(
        localized: "unarchived since it was done", bundle: .module,
        comment: "Archive reports: why a rule left a session.")
    case .overLimit:
      String(
        localized: "over the rule's limit", bundle: .module,
        comment: "Archive reports: why a rule left a session.")
    }
  }

  private var markdown: String {
    text.markdown(report, title: title, synthesis: paragraph)
  }
}

/// One session: its badge, name, dates and running time, its sentences and its resources.
private struct SessionReportRow: View {
  let model: AppModel
  let session: ArchiveReport.Session
  let text: ArchiveReportText

  var body: some View {
    let snapshot = session.snapshot
    VStack(alignment: .leading, spacing: 6) {
      HStack(alignment: .firstTextBaseline, spacing: 8) {
        SessionBadge(
          appearance: SessionAppearance(
            symbolName: snapshot.symbolName, colorHex: snapshot.colorHex),
          size: 18)
        VStack(alignment: .leading, spacing: 2) {
          Text(snapshot.name).font(.headline)
          Text(details).font(.caption).foregroundStyle(.secondary)
        }
        Spacer()
        if model.sessions.contains(where: {
          $0.id == snapshot.sessionID && $0.taskStatus == .archived
        }) {
          Button {
            model.showArchived(snapshot.sessionID)
            model.showWorkspaceWindow?()
          } label: {
            Text("Open", bundle: .module)
          }
          Button {
            Task { await model.restore(snapshot.sessionID) }
          } label: {
            Text("Unarchive", bundle: .module)
          }
        }
      }
      .accessibilityElement(children: .contain)
      ForEach(session.entries) { entry in
        Text(verbatim: "• \(entry.text)")
          .textSelection(.enabled)
      }
      if session.olderEntryCount > 0 {
        Text(text.olderEntries(session.olderEntryCount))
          .font(.caption)
          .foregroundStyle(.secondary)
      }
      ForEach(snapshot.workedResources) { resource in
        HStack(spacing: 6) {
          Image(systemName: Self.symbol(of: resource.kind))
            .foregroundStyle(.secondary)
            .accessibilityHidden(true)
          if let url = ArchiveReportText.webURL(of: resource) {
            Link(resource.label, destination: url)
          } else {
            Text(resource.label)
          }
          if let context = resource.context {
            Text(context).foregroundStyle(.secondary)
          }
          Text(text.involvement(resource)).foregroundStyle(.secondary)
        }
        .font(.callout)
        .accessibilityElement(children: .combine)
      }
    }
    .padding(12)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(.background.secondary, in: .rect(cornerRadius: 8))
  }

  private var details: String {
    var parts: [String] = []
    if let project = session.snapshot.project { parts.append(project) }
    let dates = text.dates(of: session.snapshot)
    if !dates.isEmpty { parts.append(dates) }
    if let running = session.snapshot.runningTime, running >= 60 {
      parts.append(text.duration(running))
    }
    if let unarchivedAt = session.unarchivedAt { parts.append(text.unarchived(unarchivedAt)) }
    return parts.joined(separator: " · ")
  }

  static func symbol(of kind: SessionResource.Kind) -> String {
    switch kind {
    case .issue: "smallcircle.filled.circle"
    case .pullRequest: "arrow.triangle.pull"
    case .branch: "arrow.triangle.branch"
    case .worktree: "folder"
    }
  }
}

/// A report in Markdown, for the save panel.
struct MarkdownDocument: FileDocument {
  static let readableContentTypes: [UTType] = [.markdown]
  let text: String
  let name: String

  init(text: String, name: String) {
    self.text = text
    self.name = name
  }

  init(configuration _: ReadConfiguration) throws {
    throw CocoaError(.featureUnsupported)
  }

  func fileWrapper(configuration _: WriteConfiguration) throws -> FileWrapper {
    FileWrapper(regularFileWithContents: Data(text.utf8))
  }
}

extension UTType {
  fileprivate static let markdown = UTType(
    importedAs: "net.daringfireball.markdown", conformingTo: .plainText)
}

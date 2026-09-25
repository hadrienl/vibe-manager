import Charts
import SwiftUI
import VibeDomain

/// Window › Usage: what the agents used, by session, agent or model, over a period.
public struct UsageWindow: View {
  private let model: AppModel
  @State private var chartShowsTokens = true
  @State private var selection: UsageRow.Key?

  public init(model: AppModel) {
    self.model = model
  }

  public var body: some View {
    if let usage = model.usage {
      content(usage)
        .onAppear { usage.startWatching(nil) }
        .onDisappear { usage.stopWatching(nil) }
    } else {
      ContentUnavailableView {
        Label {
          Text("Usage is not available", bundle: .module)
        } icon: {
          Image(systemName: "chart.bar")
        }
      }
    }
  }

  private func content(_ usage: UsageModel) -> some View {
    VStack(alignment: .leading, spacing: 12) {
      toolbar(usage)
      if !usage.isTrackingEnabled {
        Label(trackingOffSentence(usage), systemImage: "pause.circle")
          .font(.callout)
          .foregroundStyle(.secondary)
      }
      chart(usage)
        .frame(height: 140)
      table(usage)
      footer
    }
    .padding(16)
    .frame(minWidth: 640, minHeight: 440)
  }

  private func toolbar(_ usage: UsageModel) -> some View {
    HStack {
      Picker(selection: Bindable(usage).period) {
        ForEach(UsagePeriod.allCases, id: \.self) {
          Text(UsagePresentation.periodName($0)).tag($0)
        }
      } label: {
        Text("Period", bundle: .module)
      }
      .fixedSize()
      Picker(selection: Bindable(usage).grouping) {
        ForEach(UsageGrouping.allCases, id: \.self) {
          Text(UsagePresentation.groupingName($0)).tag($0)
        }
      } label: {
        Text("Group by", bundle: .module)
      }
      .pickerStyle(.segmented)
      .fixedSize()
      Spacer()
      if usage.isReading {
        ProgressView().controlSize(.small)
        Text("Reading transcripts…", bundle: .module).font(.callout).foregroundStyle(.secondary)
      }
      Picker(selection: $chartShowsTokens) {
        Text("Tokens", bundle: .module).tag(true)
        Text("Running time", bundle: .module).tag(false)
      } label: {
        Text("Chart", bundle: .module, comment: "What the chart of the Usage window shows.")
      }
      .labelsHidden()
      .fixedSize()
    }
  }

  private func chart(_ usage: UsageModel) -> some View {
    Chart(usage.report.days, id: \.self) { day in
      BarMark(
        x: .value(Text("Day", bundle: .module), day.day.start(in: .current), unit: .day),
        y: .value(
          chartShowsTokens ? Text("Tokens", bundle: .module) : Text("Hours", bundle: .module),
          chartShowsTokens
            ? Double(day.tokens.input + day.tokens.output)
            : day.runningTime / 3_600)
      )
      .foregroundStyle(by: .value(Text("Agent", bundle: .module), name(ofProvider: day.providerID)))
    }
    .chartYAxisLabel {
      if chartShowsTokens {
        Text("Tokens in + out (≈)", bundle: .module)
      } else {
        Text("Hours", bundle: .module)
      }
    }
    .accessibilityChartDescriptor(
      UsageChartDescriptor(
        days: usage.report.days, showsTokens: chartShowsTokens, providerName: name(ofProvider:)))
  }

  private func table(_ usage: UsageModel) -> some View {
    let rows = usage.report.rows + [usage.report.total]
    let grouping = usage.grouping
    return Table(rows, selection: $selection) {
      TableColumn(Text(UsagePresentation.groupingName(grouping))) { row in
        Text(title(of: row))
          .fontWeight(row.key == .total ? .semibold : .regular)
          .lineLimit(1)
      }
      .width(min: 160, ideal: 240)
      TableColumn(
        Text(
          grouping == .model
            ? LocalizedStringResource(
              "Running (configured model)", bundle: .module,
              comment:
                "A column of the Usage window: running time, counted for the configured model."
            )
            : LocalizedStringResource(
              "usage.column.running", defaultValue: "Running", bundle: .module,
              comment: "A column of the Usage window: running time. Not the state of a session."))
      ) { row in
        Text(UsagePresentation.duration(row.runningTime)).monospacedDigit()
      }
      TableColumn(
        Text(
          LocalizedStringResource(
            "Runs", bundle: .module, comment: "A column of the Usage window: how many runs."))
      ) { row in
        Text(row.runs.total, format: .number).monospacedDigit()
      }
      .width(50)
      TableColumn(
        Text(
          LocalizedStringResource(
            "Responses", bundle: .module,
            comment: "A column of the Usage window: how many answers the agents gave."))
      ) { row in
        Group {
          if row.hasReportedTokens {
            Text(row.responses, format: .number)
          } else {
            Text(verbatim: "—")
          }
        }
        .monospacedDigit()
      }
      .width(70)
      TableColumn(
        Text(
          grouping == .model
            ? LocalizedStringResource(
              "Tokens in (declared model)", bundle: .module,
              comment:
                "A column of the Usage window: input tokens, counted for the model the agent declared."
            )
            : LocalizedStringResource(
              "Tokens in", bundle: .module, comment: "A column of the Usage window: input tokens."))
      ) { row in
        tokenCell(row) { $0.input }
      }
      TableColumn(
        Text(
          LocalizedStringResource(
            "Tokens out", bundle: .module, comment: "A column of the Usage window: output tokens."))
      ) { row in
        tokenCell(row) { $0.output }
      }
      TableColumn(
        Text(
          LocalizedStringResource(
            "Cache read", bundle: .module,
            comment: "A column of the Usage window: tokens read from the cache."))
      ) { row in
        tokenCell(row) { $0.cacheRead }
      }
    }
    .contextMenu(forSelectionType: UsageRow.Key.self) { _ in
    } primaryAction: { keys in
      // A double-click on a session shows it in the main window.
      guard let key = keys.first, case .session(let id) = key else { return }
      model.select(id)
    }
  }

  private func tokenCell(_ row: UsageRow, _ value: (TokenCounts) -> Int) -> some View {
    Group {
      if row.hasReportedTokens {
        Text("≈ " + UsagePresentation.tokens(value(row.tokens)))
      } else {
        Text(verbatim: "—")
          .help(Text("No token usage was reported for this row.", bundle: .module))
      }
    }
    .monospacedDigit()
  }

  private var footer: some View {
    VStack(alignment: .leading, spacing: 4) {
      Label {
        Text("Cost: not available — neither CLI reports a reliable cost.", bundle: .module)
      } icon: {
        Image(systemName: "info.circle")
      }
      .help(UsagePresentation.costExplanation)
      Text(
        String(localized: "Tokens (≈) are read from the agents' own transcripts.", bundle: .module)
          + " " + UsagePresentation.privacyNote
      )
      .help(UsagePresentation.tokensExplanation)
    }
    .font(.caption)
    .foregroundStyle(.secondary)
  }

  private func trackingOffSentence(_ usage: UsageModel) -> String {
    guard let since = usage.trackingOffSince else {
      return String(localized: "Usage tracking is off.", bundle: .module)
    }
    return String(
      localized:
        "Usage tracking is off since \(since.formatted(date: .abbreviated, time: .shortened)). Turn it on in Settings.",
      bundle: .module, comment: "A date and time.")
  }

  private func title(of row: UsageRow) -> String {
    switch row.key {
    case .total:
      return String(
        localized: "Total", bundle: .module, comment: "The last row of the Usage window's table.")
    case .session(let id):
      guard let session = model.sessions.first(where: { $0.id == id }) else {
        return String(localized: "Deleted session", bundle: .module)
      }
      return session.status == .archived
        ? String(
          localized: "\(session.name) (archived)", bundle: .module, comment: "A session's name.")
        : session.name
    case .provider(let id):
      return name(ofProvider: id)
    case .model(let providerID, let model):
      let modelName =
        model
        ?? String(
          localized: "Default", bundle: .module,
          comment: "The model an agent uses when none was chosen.")
      return "\(name(ofProvider: providerID)) · \(modelName)"
    }
  }

  private func name(ofProvider id: String) -> String {
    model.agentNames[id] ?? id
  }
}

/// What VoiceOver reads of the chart: one series per agent, one value per day.
private struct UsageChartDescriptor: AXChartDescriptorRepresentable {
  let days: [UsageDay]
  let showsTokens: Bool
  let providerName: (String) -> String

  func makeChartDescriptor() -> AXChartDescriptor {
    let dates = days.map { $0.day.description }
    let orderedDates = Array(Set(dates)).sorted()
    let values = days.map(value)
    let x = AXCategoricalDataAxisDescriptor(
      title: String(localized: "Day", bundle: .module), categoryOrder: orderedDates)
    let y = AXNumericDataAxisDescriptor(
      title: showsTokens
        ? String(localized: "Tokens in and out, approximate", bundle: .module)
        : String(localized: "Hours", bundle: .module),
      range: 0...max(values.max() ?? 1, 1), gridlinePositions: []
    ) { value in
      showsTokens ? UsagePresentation.tokens(Int(value)) : String(format: "%.1f h", value)
    }
    let series = Dictionary(grouping: days, by: \.providerID).sorted { $0.key < $1.key }.map {
      providerID, entries in
      AXDataSeriesDescriptor(
        name: providerName(providerID), isContinuous: false,
        dataPoints: entries.map { AXDataPoint(x: $0.day.description, y: value($0)) })
    }
    return AXChartDescriptor(
      title: showsTokens
        ? String(localized: "Tokens per day", bundle: .module)
        : String(localized: "Running time per day", bundle: .module),
      summary: nil, xAxis: x,
      yAxis: y, additionalAxes: [], series: series)
  }

  private func value(_ day: UsageDay) -> Double {
    showsTokens ? Double(day.tokens.input + day.tokens.output) : day.runningTime / 3_600
  }
}

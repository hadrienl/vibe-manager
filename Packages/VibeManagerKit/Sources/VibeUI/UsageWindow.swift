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
      ContentUnavailableView("Usage is not available", systemImage: "chart.bar")
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
      Picker("Period", selection: Bindable(usage).period) {
        ForEach(UsagePeriod.allCases, id: \.self) {
          Text(UsagePresentation.periodName($0)).tag($0)
        }
      }
      .fixedSize()
      Picker("Group by", selection: Bindable(usage).grouping) {
        ForEach(UsageGrouping.allCases, id: \.self) {
          Text(UsagePresentation.groupingName($0)).tag($0)
        }
      }
      .pickerStyle(.segmented)
      .fixedSize()
      Spacer()
      if usage.isReading {
        ProgressView().controlSize(.small)
        Text("Reading transcripts…").font(.callout).foregroundStyle(.secondary)
      }
      Picker("Chart", selection: $chartShowsTokens) {
        Text("Tokens").tag(true)
        Text("Running time").tag(false)
      }
      .labelsHidden()
      .fixedSize()
    }
  }

  private func chart(_ usage: UsageModel) -> some View {
    Chart(usage.report.days, id: \.self) { day in
      BarMark(
        x: .value("Day", day.day.start(in: .current), unit: .day),
        y: .value(
          chartShowsTokens ? "Tokens" : "Hours",
          chartShowsTokens
            ? Double(day.tokens.input + day.tokens.output)
            : day.runningTime / 3_600)
      )
      .foregroundStyle(by: .value("Agent", name(ofProvider: day.providerID)))
    }
    .chartYAxisLabel(chartShowsTokens ? "Tokens in + out (≈)" : "Hours")
    .accessibilityChartDescriptor(
      UsageChartDescriptor(
        days: usage.report.days, showsTokens: chartShowsTokens, providerName: name(ofProvider:)))
  }

  private func table(_ usage: UsageModel) -> some View {
    let rows = usage.report.rows + [usage.report.total]
    let grouping = usage.grouping
    return Table(rows, selection: $selection) {
      TableColumn(UsagePresentation.groupingName(grouping)) { row in
        Text(title(of: row))
          .fontWeight(row.key == .total ? .semibold : .regular)
          .lineLimit(1)
      }
      .width(min: 160, ideal: 240)
      TableColumn(grouping == .model ? "Running (configured model)" : "Running") { row in
        Text(UsagePresentation.duration(row.runningTime)).monospacedDigit()
      }
      TableColumn("Runs") { row in
        Text("\(row.runs.total)").monospacedDigit()
      }
      .width(50)
      TableColumn("Responses") { row in
        Text(row.hasReportedTokens ? "\(row.responses)" : "—").monospacedDigit()
      }
      .width(70)
      TableColumn(grouping == .model ? "Tokens in (declared model)" : "Tokens in") { row in
        tokenCell(row) { $0.input }
      }
      TableColumn("Tokens out") { row in
        tokenCell(row) { $0.output }
      }
      TableColumn("Cache read") { row in
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
        Text("—").help("No token usage was reported for this row.")
      }
    }
    .monospacedDigit()
  }

  private var footer: some View {
    VStack(alignment: .leading, spacing: 4) {
      Label(
        "Cost: not available — neither CLI reports a reliable cost.", systemImage: "info.circle"
      )
      .help(UsagePresentation.costExplanation)
      Text("Tokens (≈) are read from the agents' own transcripts. " + UsagePresentation.privacyNote)
        .help(UsagePresentation.tokensExplanation)
    }
    .font(.caption)
    .foregroundStyle(.secondary)
  }

  private func trackingOffSentence(_ usage: UsageModel) -> String {
    guard let since = usage.trackingOffSince else { return "Usage tracking is off." }
    return
      "Usage tracking is off since \(since.formatted(date: .abbreviated, time: .shortened)). Turn it on in Settings."
  }

  private func title(of row: UsageRow) -> String {
    switch row.key {
    case .total:
      return "Total"
    case .session(let id):
      guard let session = model.sessions.first(where: { $0.id == id }) else {
        return "Deleted session"
      }
      return session.status == .archived ? "\(session.name) (archived)" : session.name
    case .provider(let id):
      return name(ofProvider: id)
    case .model(let providerID, let model):
      return "\(name(ofProvider: providerID)) · \(model ?? "Default")"
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
    let x = AXCategoricalDataAxisDescriptor(title: "Day", categoryOrder: orderedDates)
    let y = AXNumericDataAxisDescriptor(
      title: showsTokens ? "Tokens in and out, approximate" : "Hours",
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
      title: showsTokens ? "Tokens per day" : "Running time per day", summary: nil, xAxis: x,
      yAxis: y, additionalAxes: [], series: series)
  }

  private func value(_ day: UsageDay) -> Double {
    showsTokens ? Double(day.tokens.input + day.tokens.output) : day.runningTime / 3_600
  }
}

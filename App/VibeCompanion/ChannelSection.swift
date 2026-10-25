import CompanionCore
import CoreTransferable
import SwiftUI
import UniformTypeIdentifiers

/// The active channel's state and measures (#368), below the Mac's: how it opened, the path it
/// takes, the echo's round trips, and the export of every sample.
struct ChannelSection: View {
  @Environment(CompanionModel.self) private var model
  @Environment(CompanionChannel.self) private var channel

  var body: some View {
    Section {
      LabeledContent("State") {
        HStack(spacing: 6) {
          Circle().fill(tint).frame(width: 10, height: 10).accessibilityHidden(true)
          Text(verbatim: state).multilineTextAlignment(.trailing)
        }
      }
      LabeledContent("Mac") {
        Text(verbatim: channel.remote ?? "–").font(.footnote.monospaced())
      }
      LabeledContent("Setup", value: Self.milliseconds(channel.setup))
      LabeledContent("Path") {
        VStack(alignment: .trailing, spacing: 2) {
          Text(verbatim: pathLabel)
          if let address = channel.pathAddress {
            Text(verbatim: address).font(.caption2.monospaced()).foregroundStyle(.secondary)
          }
        }
      }
      LabeledContent("Last RTT", value: Self.milliseconds(channel.roundTrips.last))
      LabeledContent(
        "RTT p50 / p95",
        value:
          "\(Self.milliseconds(channel.roundTrips.p50)) / \(Self.milliseconds(channel.roundTrips.p95))"
      )
      LabeledContent("Time Through Relay", value: share)
      LabeledContent("Switches", value: "\(channel.ledger.switches)")
      LabeledContent("Samples", value: "\(channel.samples.count)")
      Button("Reconnect") { channel.open(to: model.selectedMac) }
      ShareLink(
        item: EchoExport(text: channel.csv),
        preview: SharePreview(Text("iroh Echoes (\(channel.samples.count))"))
      ) {
        Label("Export Samples (CSV)", systemImage: "square.and.arrow.up")
      }
      .disabled(channel.samples.isEmpty)
    } header: {
      Text("Direct Channel · iroh")
    } footer: {
      Text(
        "One echo a second while the app is open; RTT over the last \(CompanionEcho.window). n0’s public relays as a fallback, CloudKit if the channel fails."
      )
    }
  }

  private var state: String {
    switch channel.phase {
    case .closed: String(localized: "closed")
    case .noEndpoint: String(localized: "the Mac publishes no endpoint")
    case .connecting: String(localized: "connecting…")
    case .connected:
      channel.path == .relay
        ? String(localized: "connected, relay") : String(localized: "connected, direct")
    case .failed(let reason): String(localized: "failed → CloudKit (\(reason))")
    }
  }

  private var tint: Color {
    switch channel.phase {
    case .connected: channel.path == .relay ? .orange : .green
    case .connecting: .yellow
    case .failed: .red
    case .closed, .noEndpoint: .secondary
    }
  }

  private var pathLabel: String {
    guard channel.phase == .connected else { return "–" }
    switch channel.path {
    case .direct: return String(localized: "direct")
    case .relay: return String(localized: "relay")
    case .unknown: return String(localized: "unknown")
    }
  }

  private var share: String {
    channel.relayShare.map { $0.formatted(.percent.precision(.fractionLength(0))) } ?? "–"
  }

  static func milliseconds(_ value: Double?) -> String {
    value.map { $0.formatted(.number.precision(.fractionLength(1))) + " ms" } ?? "–"
  }
}

/// The samples, shared as a CSV file.
private struct EchoExport: Transferable {
  let text: String

  static var transferRepresentation: some TransferRepresentation {
    DataRepresentation(exportedContentType: .commaSeparatedText) { export in
      Data(export.text.utf8)
    }
    .suggestedFileName("vibe-companion-echo.csv")
  }
}

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
      LabeledContent("État") {
        HStack(spacing: 6) {
          Circle().fill(tint).frame(width: 10, height: 10).accessibilityHidden(true)
          Text(verbatim: state).multilineTextAlignment(.trailing)
        }
      }
      LabeledContent("Mac") {
        Text(verbatim: channel.remote ?? "–").font(.footnote.monospaced())
      }
      LabeledContent("Établissement", value: Self.milliseconds(channel.setup))
      LabeledContent("Chemin") {
        VStack(alignment: .trailing, spacing: 2) {
          Text(verbatim: pathLabel)
          if let address = channel.pathAddress {
            Text(verbatim: address).font(.caption2.monospaced()).foregroundStyle(.secondary)
          }
        }
      }
      LabeledContent("RTT dernier", value: Self.milliseconds(channel.roundTrips.last))
      LabeledContent(
        "RTT p50 / p95",
        value:
          "\(Self.milliseconds(channel.roundTrips.p50)) / \(Self.milliseconds(channel.roundTrips.p95))"
      )
      LabeledContent("Temps en relais", value: share)
      LabeledContent("Bascules", value: "\(channel.ledger.switches)")
      LabeledContent("Échantillons", value: "\(channel.samples.count)")
      Button("Reconnecter") { channel.open(to: model.selectedMac) }
      ShareLink(
        item: EchoExport(text: channel.csv),
        preview: SharePreview("Échos iroh (\(channel.samples.count))")
      ) {
        Label("Exporter les échantillons (CSV)", systemImage: "square.and.arrow.up")
      }
      .disabled(channel.samples.isEmpty)
    } header: {
      Text("Canal direct · iroh")
    } footer: {
      Text(
        "Un écho par seconde, app au premier plan ; RTT sur les \(CompanionEcho.window) derniers. Relais publics n0 en repli, CloudKit si le canal échoue."
      )
    }
  }

  private var state: String {
    switch channel.phase {
    case .closed: "fermé"
    case .noEndpoint: "le Mac ne publie pas d’endpoint"
    case .connecting: "connexion…"
    case .connected: channel.path == .relay ? "connecté, relais" : "connecté, direct"
    case .failed(let reason): "échec → CloudKit (\(reason))"
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
    case .direct: return "direct"
    case .relay: return "relais"
    case .unknown: return "inconnu"
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

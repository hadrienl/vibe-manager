import SwiftUI
import VibeApplication
import VibeConversationUI

/// Settings › Dictation (#340): which speech model the composer's microphone runs, what each one
/// takes on disk, and the language spoken.
struct DictationSettingsView: View {
  @Bindable var dictation: DictationController
  @Environment(\.locale) private var locale

  var body: some View {
    Form {
      Section {
        Picker(selection: $dictation.settings.variant) {
          ForEach(DictationModelVariant.allCases, id: \.self) { variant in
            Text(verbatim: Self.name(of: variant)).tag(variant)
          }
        } label: {
          Text("Model", bundle: .module, comment: "The speech model dictation runs.")
          Text(
            """
            Large understands technical words and every language best. Small is lighter, for a Mac \
            with little memory.
            """,
            bundle: .module)
        }
        .disabled(dictation.phase != .idle)
        ForEach(DictationModelVariant.allCases, id: \.self) { variant in
          modelRow(variant)
        }
      } header: {
        Text("Speech Model", bundle: .module, comment: "A section of Settings › Dictation.")
      } footer: {
        Text(
          """
          Dictation runs on this Mac, with Whisper: what you say is never sent anywhere. A model \
          is downloaded once, from Hugging Face, the first time you dictate.
          """,
          bundle: .module
        )
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
      }
      Section {
        Picker(selection: $dictation.settings.language) {
          Text("Automatic", bundle: .module, comment: "The language dictated: the one heard.")
            .tag(String?.none)
          ForEach(languages, id: \.code) { language in
            Text(verbatim: language.name).tag(Optional(language.code))
          }
        } label: {
          Text("Language", bundle: .module, comment: "The language dictated.")
          Text(
            "Automatic tells the language from what it hears. Choose one if it guesses wrong.",
            bundle: .module)
        }
      }
    }
    .formStyle(.grouped)
  }

  /// A model: what it weighs, downloaded or not, and the way to download or delete it.
  @ViewBuilder
  private func modelRow(_ variant: DictationModelVariant) -> some View {
    let isSelected = dictation.settings.variant == variant
    LabeledContent {
      if isSelected, dictation.owner == nil, case .downloading(let fraction) = dictation.phase {
        ProgressView(value: fraction).frame(width: 120)
      } else if isSelected, dictation.owner == nil, dictation.phase == .preparing {
        ProgressView().controlSize(.small)
      } else if dictation.installedSizes[variant] != nil {
        Button(role: .destructive) {
          Task { await dictation.removeModel(variant) }
        } label: {
          Text("Delete", bundle: .module, comment: "Deletes a speech model from the disk.")
        }
        .disabled(dictation.phase != .idle)
      } else if isSelected {
        Button {
          dictation.downloadSelectedModel()
        } label: {
          Text("Download", bundle: .module, comment: "Downloads a speech model.")
        }
        .disabled(dictation.phase != .idle)
      }
    } label: {
      Text(verbatim: Self.name(of: variant))
      if let size = dictation.installedSizes[variant] {
        Text("Downloaded · \(Self.bytes(size)) on disk", bundle: .module)
      } else if isSelected, dictation.owner == nil, dictation.problem == .downloadFailed {
        Text("The download failed. Check the connection and try again.", bundle: .module)
      } else {
        Text("Not downloaded · \(Self.bytes(variant.downloadSize))", bundle: .module)
      }
    }
  }

  /// Its name as Whisper's authors give it: not translated.
  static func name(of variant: DictationModelVariant) -> String {
    switch variant {
    case .small: "Whisper Small"
    case .largeTurbo: "Whisper Large v3 Turbo"
    }
  }

  static func bytes(_ count: Int64) -> String {
    ByteCountFormatter.string(fromByteCount: count, countStyle: .file)
  }

  /// The languages offered, named in the user's language, in its alphabetical order.
  private var languages: [(code: String, name: String)] {
    DictationSettings.languages
      .map { ($0, locale.localizedString(forLanguageCode: $0) ?? $0) }
      .map { (code: $0.0, name: $0.1.prefix(1).uppercased() + $0.1.dropFirst()) }
      .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
  }
}

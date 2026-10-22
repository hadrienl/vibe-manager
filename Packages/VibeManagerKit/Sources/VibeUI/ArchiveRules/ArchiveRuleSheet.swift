import SwiftUI
import VibeApplication
import VibeDomain

/// The sheet of a new rule, a protection, or a rule refined (#405).
struct ArchiveRuleSheet: View {
  @Bindable var model: ArchiveRuleSheetModel
  let palette: [ArchiveRuleContext.Color]
  let close: () -> Void
  @State private var bench: ArchiveRuleBenchModel?
  @FocusState private var sentenceFocused: Bool

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      header
      Divider()
      ScrollView {
        VStack(alignment: .leading, spacing: 18) {
          sentenceField
          if let question = model.question {
            questionView(question)
          }
          if let current = model.current {
            explanation(current)
            preview
          }
        }
        .padding(24)
      }
      Divider()
      footer
    }
    .frame(minWidth: 760, idealWidth: 900, minHeight: 560, idealHeight: 700)
    .task {
      await model.loadOptions()
      sentenceFocused = true
    }
    // Closed while an agent translates: its process is stopped, not left to time out.
    .onDisappear { if model.isGenerating { model.cancel() } }
    // A name another rule has: asked for another one, never replaced.
    .sheet(
      isPresented: Binding(
        get: { !model.renames.isEmpty }, set: { if !$0 { model.cancelRenames() } })
    ) {
      ArchiveRuleRenameView(model: model) { close() }
    }
    .sheet(item: $bench) { bench in
      ArchiveRuleBenchView(model: bench) { refinement in
        self.bench = nil
        if let refinement { model.refinement = refinement }
      }
    }
  }

  private var title: Text {
    switch model.purpose {
    case .newRules:
      Text("New Rule", bundle: .module, comment: "The title of the sheet that makes archive rules.")
    case .refine:
      Text("Refine the Rule", bundle: .module, comment: "The title of the sheet that changes an archive rule.")
    case .protection:
      Text("New Protection", bundle: .module, comment: "The title of the sheet that makes a protection of the automatic archive.")
    }
  }

  private var header: some View {
    HStack {
      title.font(.title3.bold())
      Spacer()
      if model.versions.count > 1 {
        HStack(spacing: 6) {
          Text("Versions", bundle: .module, comment: "The versions of archive rules made in the sheet.")
            .foregroundStyle(.secondary)
          ForEach(Array(model.versions.enumerated()), id: \.element.id) { index, version in
            Button {
              model.goBack(to: version)
            } label: {
              Text(verbatim: "\(index + 1)")
                .fontWeight(version == model.current ? .bold : .regular)
            }
            .buttonStyle(.bordered)
            .help(Text(verbatim: version.sentence))
            .accessibilityLabel(
              Text(
                "Version \(index + 1), \(version.sentence), \(version.agentName)", bundle: .module,
                comment: "A version of archive rules: its number, the sentence it came from, the agent."))
          }
        }
        .font(.caption)
      }
    }
    .padding(.horizontal, 24)
    .padding(.vertical, 14)
  }

  // MARK: The sentence

  private var sentenceField: some View {
    VStack(alignment: .leading, spacing: 8) {
      Group {
        if model.purpose == .protection {
          Text("Describe the sessions that must never be archived", bundle: .module, comment: "The sheet of a new protection.")
        } else {
          Text("Describe what should be archived, and when", bundle: .module, comment: "The sheet of a new archive rule.")
        }
      }
      .font(.headline)
      HStack(alignment: .top, spacing: 10) {
        TextField(
          text: $model.sentence,
          prompt: Text(
            "Archive the done sessions with a red badge on the 15th of the month.", bundle: .module,
            comment: "An example of a sentence describing an archive rule."),
          axis: .vertical
        ) {
          Text("Sentence", bundle: .module, comment: "The field of the sentence describing archive rules.")
        }
        .lineLimit(2...5)
        .textFieldStyle(.roundedBorder)
        .focused($sentenceFocused)
        .labelsHidden()
        .disabled(model.isGenerating)
        VStack(alignment: .leading, spacing: 6) {
          if model.optionsLoaded {
            Picker(selection: $model.selectedAgent) {
              ForEach(model.options) { option in
                Text(verbatim: option.descriptor.displayName).tag(Optional(option.id))
              }
            } label: {
              Text("Agent", bundle: .module, comment: "Which agent translates the sentence into archive rules.")
            }
            .disabled(model.options.isEmpty || model.isGenerating)
          } else {
            ProgressView().controlSize(.small)
          }
          Button {
            model.translate()
          } label: {
            Text("Translate", bundle: .module, comment: "Asks the agent to translate the sentence into archive rules.")
              .frame(maxWidth: .infinity)
          }
          .buttonStyle(.borderedProminent)
          .disabled(
            model.sentence.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
              || model.options.isEmpty || model.isGenerating)
          .accessibilityIdentifier("archive-rule-translate")
        }
        .frame(width: 200)
      }
      if let agent = model.generatingAgent {
        HStack(spacing: 8) {
          ProgressView().controlSize(.small)
          if model.isRetrying {
            Text(
              "The first answer could not be used: it is asked once more.", bundle: .module,
              comment: "The sheet of a new archive rule, while the agent is asked a second time.")
          } else {
            Text("\(agent) is translating…", bundle: .module, comment: "The sheet of a new archive rule. The argument is an agent's name.")
          }
          Spacer()
          Button {
            model.cancel()
          } label: {
            Text("Cancel", bundle: .module, comment: "Stops the translation of a sentence into archive rules.")
          }
          .keyboardShortcut(.cancelAction)
        }
        .foregroundStyle(.secondary)
      }
      if model.optionsLoaded, model.options.isEmpty {
        Text(
          "No agent can translate a sentence now. Claude Code or Codex must be installed and signed in.",
          bundle: .module, comment: "The sheet of a new archive rule, without agents.")
        .foregroundStyle(.orange)
      }
      if let problem = model.problem {
        Label {
          Text(verbatim: model.message(of: problem))
        } icon: {
          Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
        }
      }
    }
  }

  private func questionView(_ question: ArchiveRuleQuestion) -> some View {
    VStack(alignment: .leading, spacing: 10) {
      HStack(alignment: .top, spacing: 10) {
        Image(systemName: "questionmark.circle.fill").font(.title2).foregroundStyle(.orange)
          .accessibilityHidden(true)
        VStack(alignment: .leading, spacing: 2) {
          Text(
            "\(model.options.first { $0.id == model.selectedAgent }?.descriptor.displayName ?? "") asks",
            bundle: .module, comment: "Above the question of the agent. The argument is its name.")
          .font(.caption.bold()).foregroundStyle(.secondary)
          Text(verbatim: question.text).font(.headline)
        }
      }
      if !question.choices.isEmpty {
        Picker(selection: $model.chosenAnswer) {
          ForEach(question.choices, id: \.self) { choice in
            Text(verbatim: choice).tag(Optional(choice))
          }
        } label: {
          Text("Answers", bundle: .module, comment: "The answers offered to the agent's question.")
        }
        .pickerStyle(.radioGroup)
        .labelsHidden()
        .padding(.leading, 34)
      }
      HStack {
        Spacer()
        Button {
          sentenceFocused = true
        } label: {
          Text("Rephrase", bundle: .module, comment: "Goes back to the sentence instead of answering the agent's question.")
        }
        Button {
          if let answer = model.chosenAnswer { model.answer(answer) }
        } label: {
          Text("Answer", bundle: .module, comment: "Answers the agent's question.")
        }
        .buttonStyle(.borderedProminent)
        .disabled(model.chosenAnswer == nil)
      }
    }
    .padding(14)
    .background(.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
  }

  // MARK: The version

  private func explanation(_ version: ArchiveRuleSheetModel.Version) -> some View {
    let explanation = model.rules.explanation
    return VStack(alignment: .leading, spacing: 10) {
      Text("What these rules will do", bundle: .module, comment: "A section of the sheet of a new archive rule.")
        .font(.headline)
      ForEach(Array(version.document.rules.enumerated()), id: \.offset) { _, rule in
        VStack(alignment: .leading, spacing: 4) {
          HStack {
            Text(verbatim: rule.name).fontWeight(.semibold)
            Spacer()
            Text(verbatim: explanation.shortSchedule(rule.schedule))
              .font(.caption.bold()).padding(.horizontal, 8).padding(.vertical, 2)
              .background(.quaternary, in: Capsule())
          }
          Text(verbatim: explanation.sentence(of: rule)).fixedSize(horizontal: false, vertical: true)
        }
        .padding(12)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 10))
        .accessibilityElement(children: .combine)
      }
      ForEach(Array(version.document.protections.enumerated()), id: \.offset) { _, protection in
        Label {
          Text(verbatim: explanation.sentence(of: protection))
        } icon: {
          Image(systemName: "checkmark.shield").foregroundStyle(.green)
        }
      }
      if !version.assumptions.isEmpty {
        let chosen = version.assumptions.map { "« \($0.said) » → \($0.chosen)" }
          .formatted(.list(type: .and))
        Text("Chosen for you: \(chosen)", bundle: .module, comment: "What the agent decided where the sentence left it open.")
          .font(.caption).foregroundStyle(.secondary)
      }
    }
  }

  private var preview: some View {
    VStack(alignment: .leading, spacing: 8) {
      HStack(alignment: .firstTextBaseline) {
        Text("On your sessions", bundle: .module, comment: "A section of the sheet of a new archive rule: what the rules would do with the real sessions.")
          .font(.headline)
        Spacer()
        let times = model.nextTimes.map {
          $0.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated))
        }
        if !times.isEmpty {
          Text("Next times: \(times.joined(separator: " · "))", bundle: .module, comment: "The next times archive rules run.")
            .font(.caption).foregroundStyle(.secondary)
        }
      }
      let rows = model.preview
      if rows.isEmpty {
        Text("No done session would be archived now.", bundle: .module, comment: "The preview of archive rules.")
          .foregroundStyle(.secondary)
      }
      ForEach(rows) { row in
        HStack(spacing: 10) {
          RoundedRectangle(cornerRadius: 4)
            .fill(Color(hex: row.session.appearance.colorHex)).frame(width: 16, height: 16)
            .accessibilityHidden(true)
          Text(verbatim: row.session.name).lineLimit(1)
          Spacer()
          Text(verbatim: verdict(row)).font(.callout)
            .foregroundStyle(row.verdict == .archive ? .primary : .secondary)
        }
        .accessibilityElement(children: .combine)
      }
    }
  }

  private func verdict(_ row: ArchiveRuleSheetModel.PreviewRow) -> String {
    let rule = row.ruleName ?? ""
    switch row.verdict {
    case .archive:
      let date = row.when?.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated).hour().minute()) ?? ""
      return String(localized: "\(date) · “\(rule)”", bundle: .module, comment: "When a session would be archived, and by which rule.")
    case .protected:
      return String(localized: "Never: protected", bundle: .module, comment: "The preview of archive rules: a protected session.")
    case .running:
      return String(localized: "Skipped while something runs in it", bundle: .module, comment: "The preview of archive rules.")
    case .unarchived:
      return String(localized: "Skipped: you took it out of the archive", bundle: .module, comment: "The preview of archive rules.")
    default:
      return ""
    }
  }

  // MARK: The foot

  private var footer: some View {
    HStack(spacing: 10) {
      if model.current != nil {
        TextField(
          text: $model.refinement,
          prompt: Text(
            "Refine: “rather on Friday at noon”, “except the site project”…", bundle: .module,
            comment: "Examples of a refinement of archive rules.")
        ) {
          Text("Refine", bundle: .module, comment: "The field to refine archive rules.")
        }
        .textFieldStyle(.roundedBorder)
        .onSubmit { model.refine() }
        .disabled(model.isGenerating)
        Button {
          model.refine()
        } label: {
          Text("Refine", bundle: .module, comment: "Asks the agent for a new version of the rules.")
        }
        .disabled(model.refinement.trimmingCharacters(in: .whitespaces).isEmpty || model.isGenerating)
        Button {
          if let current = model.current {
            bench = ArchiveRuleBenchModel(
              document: current.document, origin: .draft, rules: model.rules, palette: palette)
          }
        } label: {
          Text("Test on the Bench", bundle: .module, comment: "Opens the test bench of the archive rules made in the sheet.")
        }
        .disabled(model.current?.document.rules.isEmpty ?? true)
      } else {
        Spacer()
      }
      Button(role: .cancel) {
        model.cancel()
        close()
      } label: {
        Text("Cancel", bundle: .module, comment: "Closes the sheet of a new archive rule without saving.")
      }
      if model.purpose != .protection {
        Button {
          Task { if await model.save(trial: true) { close() } }
        } label: {
          Text("Try First", bundle: .module, comment: "Saves archive rules that archive nothing until turned on.")
        }
        .disabled(model.current == nil || model.isGenerating)
      }
      Button {
        Task { if await model.save(trial: false) { close() } }
      } label: {
        if model.purpose == .protection {
          Text("Add", bundle: .module, comment: "Saves a protection of the automatic archive.")
        } else {
          Text("Turn On", bundle: .module, comment: "Saves archive rules and turns them on.")
        }
      }
      .buttonStyle(.borderedProminent)
      .keyboardShortcut(.defaultAction)
      .disabled(
        model.current == nil || model.isGenerating
          || (model.purpose == .protection && model.current?.document.protections.isEmpty == true))
    }
    .padding(.horizontal, 24)
    .padding(.vertical, 14)
  }
}

/// Asks for another name for each rule whose name another rule already has.
private struct ArchiveRuleRenameView: View {
  @Bindable var model: ArchiveRuleSheetModel
  let saved: () -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 14) {
      Text("Rename the Rule", bundle: .module, comment: "The title of the sheet asking for another name for an archive rule.")
        .font(.headline)
      ForEach($model.renames) { $rename in
        VStack(alignment: .leading, spacing: 6) {
          Text(
            "A rule is already named “\(rename.original)”. Give this one another name.",
            bundle: .module, comment: "Renaming an archive rule whose name is taken.")
          .fixedSize(horizontal: false, vertical: true)
          TextField(text: $rename.name, prompt: Text(verbatim: rename.original)) {
            Text("New name", bundle: .module, comment: "The field of an archive rule's new name.")
          }
          .textFieldStyle(.roundedBorder)
        }
      }
      if let problem = model.renameProblem, model.renames.contains(where: { !$0.name.isEmpty }) {
        Text(verbatim: problem).font(.callout).foregroundStyle(.orange)
      }
      HStack {
        Spacer()
        Button(role: .cancel) {
          model.cancelRenames()
        } label: {
          Text("Cancel", bundle: .module, comment: "Goes back to the archive rule without renaming it.")
        }
        .keyboardShortcut(.cancelAction)
        Button {
          Task { if await model.saveRenamed() { saved() } }
        } label: {
          Text("Save", bundle: .module, comment: "Saves archive rules under their new names.")
        }
        .buttonStyle(.borderedProminent)
        .keyboardShortcut(.defaultAction)
        .disabled(model.renameProblem != nil)
      }
    }
    .padding(20)
    .frame(width: 420)
  }
}

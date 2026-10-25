import SwiftUI
import VibeApplication
import VibeDomain

/// Settings › Automatic Archive (#405): the only place where rules are made, refined, tried,
/// turned on and paused. A rule is shown by what it does, never by its text.
struct ArchiveRulesSettingsView: View {
  @Bindable var model: AppModel
  @Bindable var rules: ArchiveRulesModel
  @State private var sheet: ArchiveRuleSheetModel?
  @State private var bench: ArchiveRuleBenchModel?
  /// “Not What I Wanted” from the bench: the sheet to refine opens once the bench is gone.
  @State private var pendingRefinement: (rule: StoredArchiveRule, text: String)?

  var body: some View {
    Form {
      Section {
        Text(
          """
          Rules, each described in a sentence, archive done sessions at the time they say. \
          Nothing is deleted, and a session where something runs is always skipped.
          """,
          bundle: .module, comment: "The head of Settings › Automatic Archive."
        )
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
        if rules.problem == .unreadable {
          Label {
            Text(
              "The rules could not be read: they were written by a later version, or damaged. None runs.",
              bundle: .module, comment: "Settings › Automatic Archive.")
          } icon: {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
          }
        }
      }
      Section {
        if rules.lines.isEmpty {
          Text(
            "No rule yet. Describe one in a sentence: “Archive the red sessions on the 15th of the month.”",
            bundle: .module, comment: "Settings › Automatic Archive, without any rule.")
          .foregroundStyle(.secondary)
        }
        ForEach(rules.lines) { line in
          ArchiveRuleRow(
            line: line, rules: rules,
            test: { bench = benchModel(for: line) },
            redo: { sheet = sheetModel(.refine(line.stored)) })
        }
      } header: {
        HStack {
          Text("Rules", bundle: .module, comment: "A section of Settings › Automatic Archive.")
          Spacer()
          Button {
            sheet = sheetModel(.newRules)
          } label: {
            Text("New Rule…", bundle: .module, comment: "Settings › Automatic Archive.")
          }
          .disabled(rules.problem == .unreadable)
          .accessibilityIdentifier("archive-rules-new")
        }
      }
      Section {
        ForEach(rules.protectionLines, id: \.stored.id) { line in
          HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: "checkmark.shield").foregroundStyle(.green)
              .accessibilityHidden(true)
            if let explanation = line.explanation {
              Text(verbatim: explanation).fixedSize(horizontal: false, vertical: true)
            } else {
              Text(
                "This protection no longer reads with this version: no rule runs until it is removed.",
                bundle: .module, comment: "Settings › Automatic Archive.")
              .foregroundStyle(.orange)
            }
            Spacer()
            Button {
              Task { await rules.remove(protection: line.stored.id) }
            } label: {
              Text("Remove", bundle: .module, comment: "Removes a protection of the automatic archive.")
            }
          }
          .accessibilityElement(children: .combine)
        }
      } header: {
        HStack {
          Text("Protections", bundle: .module, comment: "A section of Settings › Automatic Archive.")
          Spacer()
          Button {
            sheet = sheetModel(.protection)
          } label: {
            Text("Add a Protection…", bundle: .module, comment: "Settings › Automatic Archive.")
          }
          .disabled(rules.problem == .unreadable)
        }
      } footer: {
        Text(
          "A protected session is never archived by a rule, whatever the rule.", bundle: .module,
          comment: "Settings › Automatic Archive.")
        .foregroundStyle(.secondary)
      }
      Section {
        Toggle(
          isOn: Binding(
            get: { rules.set.notifies },
            set: { notifies in Task { await rules.setNotifies(notifies) } })
        ) {
          Text(
            "Notify me after each archive", bundle: .module,
            comment: "Settings › Automatic Archive: a notification when a rule archived sessions.")
        }
        .accessibilityIdentifier("archive-rules-notifies")
      }
    }
    .formStyle(.grouped)
    .task { if !rules.loaded { await rules.load() } }
    // Read again when the rules change, not each time one of them runs.
    .task(id: rules.set.rules.map(\.text) + rules.set.protections.map(\.text)) {
      await rules.refreshGitFacts()
    }
    .sheet(item: $sheet) { sheet in
      ArchiveRuleSheet(model: sheet, palette: model.archiveRuleContext().palette) {
        self.sheet = nil
      }
    }
    .sheet(
      item: $bench,
      onDismiss: {
        guard let pending = pendingRefinement else { return }
        pendingRefinement = nil
        let sheet = sheetModel(.refine(pending.rule))
        sheet.refinement = pending.text
        self.sheet = sheet
      }
    ) { bench in
      ArchiveRuleBenchView(model: bench) { refinement in
        if let refinement, case .stored(let stored) = bench.origin {
          pendingRefinement = (stored, refinement)
        }
        self.bench = nil
      }
    }
  }

  private func sheetModel(_ purpose: ArchiveRuleSheetModel.Purpose) -> ArchiveRuleSheetModel {
    ArchiveRuleSheetModel(purpose: purpose, rules: rules) { [model] in model.archiveRuleContext() }
  }

  private func benchModel(for line: ArchiveRulesModel.Line) -> ArchiveRuleBenchModel? {
    guard let rule = line.stored.rule else { return nil }
    return ArchiveRuleBenchModel(
      document: ArchiveRuleDocument(rules: [rule], protections: rules.set.readableProtections ?? []),
      origin: .stored(line.stored), rules: rules,
      palette: model.archiveRuleContext().palette)
  }

}

/// One rule: its switch, its name and what it does, when it next runs and what it last did.
private struct ArchiveRuleRow: View {
  let line: ArchiveRulesModel.Line
  let rules: ArchiveRulesModel
  let test: () -> Void
  let redo: () -> Void

  private var stored: StoredArchiveRule { line.stored }
  private var name: String { stored.rule?.name ?? "—" }

  var body: some View {
    HStack(alignment: .top, spacing: 12) {
      Toggle(
        isOn: Binding(
          get: { stored.state != .paused },
          set: { isOn in Task { await rules.setState(isOn ? .active : .paused, of: stored.id) } })
      ) {
        Text(verbatim: name)
      }
      .labelsHidden()
      .toggleStyle(.switch)
      .disabled(stored.rule == nil)
      .accessibilityIdentifier("archive-rule-switch")

      VStack(alignment: .leading, spacing: 3) {
        HStack(spacing: 6) {
          Text(verbatim: name).fontWeight(.semibold)
          if let pill { pill }
        }
        if let explanation = line.explanation {
          Text(verbatim: explanation).font(.callout).fixedSize(horizontal: false, vertical: true)
        } else {
          Text(
            "This rule no longer reads with this version of the application. Describe it again to redo it.",
            bundle: .module, comment: "Settings › Automatic Archive: a rule that cannot be read.")
          .font(.callout).foregroundStyle(.orange)
          .fixedSize(horizontal: false, vertical: true)
        }
        Text(verbatim: nextText).font(.caption).fontWeight(.medium)
        Text(verbatim: lastText).font(.caption).foregroundStyle(.secondary)
      }
      .accessibilityElement(children: .combine)
      Spacer(minLength: 8)
      if stored.rule == nil {
        Button(action: redo) {
          Text("Redo…", bundle: .module, comment: "Describes an unreadable archive rule again.")
        }
      } else {
        Button(action: test) {
          Text("Test", bundle: .module, comment: "Opens the test bench of an archive rule.")
        }
        .accessibilityIdentifier("archive-rule-test")
      }
      Menu {
        if stored.rule != nil {
          if stored.state != .active {
            Button {
              Task { await rules.setState(.active, of: stored.id) }
            } label: {
              Text("Turn On", bundle: .module, comment: "A menu of an archive rule.")
            }
          }
          if stored.state != .trial {
            Button {
              Task { await rules.setState(.trial, of: stored.id) }
            } label: {
              Text("Try First", bundle: .module, comment: "A menu of an archive rule: run it without archiving.")
            }
          }
          if stored.state != .paused {
            Button {
              Task { await rules.setState(.paused, of: stored.id) }
            } label: {
              Text("Pause", bundle: .module, comment: "A menu of an archive rule.")
            }
          }
        }
        Button(action: redo) {
          Text("Refine…", bundle: .module, comment: "A menu of an archive rule: describe a change.")
        }
        Divider()
        Button(role: .destructive) {
          Task { await rules.remove(rule: stored.id) }
        } label: {
          Text("Delete", bundle: .module, comment: "A menu of an archive rule.")
        }
      } label: {
        Image(systemName: "ellipsis")
      }
      .menuIndicator(.hidden)
      .fixedSize()
      .accessibilityLabel(
        Text("More for \(name)", bundle: .module, comment: "The menu of an archive rule, by its name."))
    }
    .padding(.vertical, 2)
  }

  private var pill: Text? {
    switch (stored.state, stored.rule == nil) {
    case (_, true), (.paused, _):
      Text("Paused", bundle: .module, comment: "A badge of an archive rule.")
        .font(.caption2.bold()).foregroundStyle(.orange)
    case (.trial, _):
      Text("On Trial", bundle: .module, comment: "A badge of an archive rule that archives nothing yet.")
        .font(.caption2.bold()).foregroundStyle(.blue)
    default:
      nil
    }
  }

  private var nextText: String {
    guard stored.runs else {
      return String(
        localized: "No next time", bundle: .module,
        comment: "Settings › Automatic Archive: a paused rule.")
    }
    let count = line.wouldArchive
    if let next = line.next {
      let date = next.formatted(
        .dateTime.weekday(.abbreviated).day().month(.abbreviated).hour().minute())
      return stored.state == .trial
        ? String(
          localized: "Next: \(date) · dry run, \(count) sessions", bundle: .module,
          comment: "Settings › Automatic Archive: when a rule on trial next runs, and how many sessions it would archive now.")
        : String(
          localized: "Next: \(date) · \(count) sessions", bundle: .module,
          comment: "Settings › Automatic Archive: when a rule next runs, and how many sessions it would archive now.")
    }
    return String(
      localized: "Continuously · \(count) sessions", bundle: .module,
      comment: "Settings › Automatic Archive: a rule that runs as soon as sessions match.")
  }

  private var lastText: String {
    guard let last = stored.lastRun else {
      return String(
        localized: "Not run yet", bundle: .module, comment: "Settings › Automatic Archive.")
    }
    let date = last.date.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated))
    if last.isTrial {
      return String(
        localized: "Last: \(date) · would have archived \(last.archived)", bundle: .module,
        comment: "Settings › Automatic Archive: what a rule on trial would have archived.")
    }
    return String(
      localized: "Last: \(date) · \(last.archived) archived, \(last.skipped) skipped",
      bundle: .module, comment: "Settings › Automatic Archive: what a rule's last run did.")
  }
}

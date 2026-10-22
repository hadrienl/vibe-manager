import SwiftUI
import VibeApplication
import VibeDomain

/// The test bench of archive rules (#405): made-up sessions over a timeline, and a cursor to read
/// where each stands on any day. `done` closes it, with a refinement when the user said “Not what
/// I wanted” of a session.
struct ArchiveRuleBenchView: View {
  @Bindable var model: ArchiveRuleBenchModel
  let done: (String?) -> Void
  @State private var editing: SessionID?
  @FocusState private var focused: Bool

  private static let infoWidth: CGFloat = 430
  private static let rowHeight: CGFloat = 78
  private static let laneHeight: CGFloat = 26

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      header
      controls
      Divider()
      ScrollView(.vertical) {
        HStack(alignment: .top, spacing: 0) {
          infoColumn
          ScrollView(.horizontal) {
            lanes
          }
        }
      }
      HStack {
        Spacer()
        Button {
          done(nil)
        } label: {
          Text("Done", bundle: .module, comment: "Closes the test bench of archive rules.")
        }
        .keyboardShortcut(.defaultAction)
      }
    }
    .padding(20)
    .frame(minWidth: 1_000, idealWidth: 1_200, minHeight: 640, idealHeight: 760)
    .focusable()
    .focused($focused)
    .focusEffectDisabled()
    .onAppear { focused = true }
    .onKeyPress(.leftArrow, phases: .down) { press in
      press.modifiers.contains(.option) ? model.jump(forward: false) : model.step(days: -1)
      return .handled
    }
    .onKeyPress(.rightArrow, phases: .down) { press in
      press.modifiers.contains(.option) ? model.jump(forward: true) : model.step(days: 1)
      return .handled
    }
  }

  // MARK: Head

  private var header: some View {
    HStack(alignment: .top) {
      VStack(alignment: .leading, spacing: 4) {
        Text("Test Bench", bundle: .module, comment: "The title of the test bench of archive rules.")
          .font(.title2.bold())
        Text(
          "\(model.sessions.count) made-up sessions · nothing is written to your sessions",
          bundle: .module, comment: "The test bench of archive rules.")
        .foregroundStyle(.secondary)
      }
      Spacer()
      Button {
        model.regenerate()
      } label: {
        Text("Regenerate", bundle: .module, comment: "Builds the made-up sessions of the test bench again.")
      }
    }
  }

  private var controls: some View {
    VStack(alignment: .leading, spacing: 8) {
      HStack(spacing: 8) {
        Picker(selection: $model.zoom) {
          Text("Day", bundle: .module, comment: "A zoom of the test bench's timeline.").tag(ArchiveRuleBenchModel.Zoom.day)
          Text("Week", bundle: .module, comment: "A zoom of the test bench's timeline.").tag(ArchiveRuleBenchModel.Zoom.week)
          Text("Month", bundle: .module, comment: "A zoom of the test bench's timeline.").tag(ArchiveRuleBenchModel.Zoom.month)
        } label: {
          Text("Scale", bundle: .module, comment: "The zoom of the test bench's timeline.")
        }
        .pickerStyle(.segmented)
        .fixedSize()
        Divider().frame(height: 18)
        Button {
          model.jump(forward: false)
        } label: {
          Text("⌥← Time", bundle: .module, comment: "Moves the test bench's cursor to the previous time a rule runs.")
        }
        Button {
          model.step(days: -1)
        } label: {
          Text("← Day", bundle: .module, comment: "Moves the test bench's cursor a day back.")
        }
        Text(verbatim: model.cursor.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated).hour().minute()))
          .monospacedDigit()
          .frame(minWidth: 150)
        Button {
          model.step(days: 1)
        } label: {
          Text("Day →", bundle: .module, comment: "Moves the test bench's cursor a day on.")
        }
        Button {
          model.jump(forward: true)
        } label: {
          Text("Time ⌥→", bundle: .module, comment: "Moves the test bench's cursor to the next time a rule runs.")
        }
        Button {
          model.today()
        } label: {
          Text("Today", bundle: .module, comment: "Moves the test bench's cursor back to now.")
        }
        Spacer()
        Stepper(value: $model.months, in: 1...12) {
          Text("\(model.months) months", bundle: .module, comment: "How far the test bench's timeline goes.")
        }
        .fixedSize()
      }
      HStack(spacing: 10) {
        Text(verbatim: model.counter)
          .fontWeight(.semibold)
          .accessibilityAddTraits(.updatesFrequently)
        Spacer()
        ForEach(model.offPeriods) { period in
          HStack(spacing: 4) {
            Image(systemName: "powersleep").accessibilityHidden(true)
            Text(
              verbatim:
                "\(period.interval.start.formatted(.dateTime.day().month(.abbreviated))) – \(period.interval.end.formatted(.dateTime.day().month(.abbreviated)))"
            )
            Button {
              model.removeOff(period)
            } label: {
              Image(systemName: "xmark.circle.fill")
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text("Turn the Mac back on", bundle: .module, comment: "Removes a period the Mac is off from the test bench."))
          }
          .font(.caption)
        }
        Button {
          model.turnOff(days: 10)
        } label: {
          Text("Mac Off for 10 Days from Here", bundle: .module, comment: "Lays a period the Mac is off on the test bench, from its cursor.")
        }
      }
      Slider(
        value: Binding(
          get: { model.cursor.timeIntervalSince(model.start) },
          set: { model.cursor = model.start.addingTimeInterval($0) }),
        in: 0...max(model.end.timeIntervalSince(model.start), 1)
      ) {
        Text("Cursor date", bundle: .module, comment: "The slider of the test bench's cursor.")
      }
      .labelsHidden()
      .accessibilityValue(Text(verbatim: model.counter))
    }
  }

  // MARK: The sessions

  private var infoColumn: some View {
    VStack(alignment: .leading, spacing: 0) {
      ForEach(Array(model.document.rules.enumerated()), id: \.offset) { index, rule in
        HStack(spacing: 6) {
          Circle().fill(Self.ruleColor(index)).frame(width: 9, height: 9)
          Text(verbatim: rule.name).fontWeight(.semibold).lineLimit(1)
          Text(verbatim: model.rules.explanation.shortSchedule(rule.schedule))
            .foregroundStyle(.secondary).lineLimit(1)
        }
        .font(.caption)
        .frame(width: Self.infoWidth, height: Self.laneHeight, alignment: .leading)
      }
      Text("The Mac's calendar", bundle: .module, comment: "A lane of the test bench: clock changes, the Mac off, catch-ups.")
        .font(.caption.bold())
        .frame(width: Self.infoWidth, height: Self.laneHeight, alignment: .leading)
      ForEach(model.sessions) { session in
        sessionInfo(session)
          .frame(width: Self.infoWidth, height: Self.rowHeight, alignment: .topLeading)
      }
    }
  }

  private func sessionInfo(_ session: BenchSession) -> some View {
    let standing = model.standing(of: session)
    return HStack(alignment: .top, spacing: 8) {
      RoundedRectangle(cornerRadius: 6)
        .fill(session.showsProjectIcon ? Color.gray : Color(hex: session.colorHex))
        .frame(width: 24, height: 24)
        .overlay {
          Image(systemName: session.showsProjectIcon ? "folder.fill" : session.symbolName)
            .font(.caption).foregroundStyle(.white)
        }
        .accessibilityHidden(true)
      VStack(alignment: .leading, spacing: 2) {
        HStack(spacing: 6) {
          Text(verbatim: session.name).fontWeight(.medium).lineLimit(1)
          Text("Example", bundle: .module, comment: "A badge on a made-up session of the test bench.")
            .font(.caption2).padding(.horizontal, 4)
            .background(.quaternary, in: Capsule())
          Text(verbatim: standingLabel(standing)).font(.caption2.bold())
            .foregroundStyle(standing == .archived ? Color.secondary : standing == .skipped ? .orange : .green)
          if model.changed(session) {
            Image(systemName: "arrow.triangle.2.circlepath").foregroundStyle(.purple)
              .accessibilityLabel(Text("Its fate changed", bundle: .module, comment: "A made-up session the new version treats otherwise."))
          }
          Spacer(minLength: 0)
          Button {
            editing = session.id
          } label: {
            Image(systemName: "slider.horizontal.3")
          }
          .buttonStyle(.borderless)
          .accessibilityLabel(Text("Change", bundle: .module, comment: "Edits a made-up session of the test bench."))
          .popover(
            isPresented: Binding(
              get: { editing == session.id }, set: { if !$0 { editing = nil } })
          ) {
            BenchSessionEditor(model: model, id: session.id)
          }
          Button {
            done(model.refinement(for: session))
          } label: {
            Text("Not What I Wanted", bundle: .module, comment: "Refines the rules from a made-up session of the test bench.")
          }
          .buttonStyle(.borderless)
          .font(.caption)
        }
        Text(verbatim: chips(session).joined(separator: " · "))
          .font(.caption2).foregroundStyle(.secondary).lineLimit(1)
        Text(verbatim: model.why(session))
          .font(.caption).lineLimit(2)
          .fixedSize(horizontal: false, vertical: true)
      }
    }
    .opacity(standing == .archived ? 0.55 : 1)
    .accessibilityElement(children: .combine)
  }

  private func standingLabel(_ standing: ArchiveRuleBenchModel.Standing) -> String {
    switch standing {
    case .present:
      String(localized: "There", bundle: .module, comment: "A made-up session still in the list at the test bench's cursor.")
    case .skipped:
      String(localized: "Skipped", bundle: .module, comment: "A made-up session a rule skipped, at the test bench's cursor.")
    case .archived:
      String(localized: "Archived", bundle: .module, comment: "A made-up session archived at the test bench's cursor.")
    }
  }

  /// What sets the session apart: its badge, column, agent, group, branch, folder, coordination,
  /// what runs.
  private func chips(_ session: BenchSession) -> [String] {
    var chips: [String] = []
    chips.append(
      session.showsProjectIcon
        ? String(localized: "project's icon", bundle: .module, comment: "A trait of a made-up session: its badge shows the project's icon.")
        : model.rules.explanation.vocabulary.color(session.colorHex))
    chips.append(String(localized: session.status(at: model.cursor).label))
    chips.append(model.rules.explanation.vocabulary.agent(session.agent))
    if let project = session.project { chips.append(project) }
    if let branch = session.branch { chips.append(branch) }
    let candidate = session.candidate(at: model.cursor)
    chips.append(
      candidate.isDirty == true
        ? String(localized: "changes", bundle: .module, comment: "A trait of a made-up session: its folder has changes.")
        : String(localized: "clean", bundle: .module, comment: "A trait of a made-up session: its folder is clean."))
    switch session.coordination {
    case .coordinator?:
      chips.append(String(localized: "coordinator", bundle: .module, comment: "A trait of a made-up session."))
    case .child?:
      chips.append(String(localized: "child", bundle: .module, comment: "A trait of a made-up session: a coordinator's child."))
    case nil: break
    }
    if candidate.isRunning {
      chips.append(String(localized: "running", bundle: .module, comment: "A trait of a made-up session: its agent runs."))
    }
    return chips
  }

  // MARK: The timeline

  private var dayWidth: Double { model.zoom.dayWidth }

  private var width: CGFloat {
    CGFloat(model.end.timeIntervalSince(model.start) / 86_400 * dayWidth)
  }

  private func x(_ date: Date) -> CGFloat {
    CGFloat(max(0, date.timeIntervalSince(model.start)) / 86_400 * dayWidth)
  }

  private var lanes: some View {
    VStack(alignment: .leading, spacing: 0) {
      ForEach(Array(model.document.rules.enumerated()), id: \.offset) { index, _ in
        Canvas { context, size in
          for due in model.dueTimes where due.rule == index {
            let missed = model.outcome.runs.contains { $0.due == due.date && $0.kind == .missed }
            let rect = CGRect(x: x(due.date) - 3, y: size.height / 2 - 6, width: 6, height: 12)
            context.fill(
              Path(roundedRect: rect, cornerRadius: 2),
              with: .color(Self.ruleColor(index).opacity(missed ? 0.3 : 1)))
          }
        }
        .frame(width: width, height: Self.laneHeight)
      }
      Canvas { context, size in
        for mark in model.calendarMarks {
          context.fill(
            Path(CGRect(x: x(mark), y: 4, width: 1.5, height: size.height - 8)),
            with: .color(.secondary))
        }
        for period in model.offPeriods {
          let rect = CGRect(
            x: x(period.interval.start), y: 6,
            width: x(period.interval.end) - x(period.interval.start), height: size.height - 12)
          context.fill(Path(rect), with: .color(.gray.opacity(0.35)))
        }
        for run in model.outcome.runs {
          if case .catchUp(let ranAt) = run.kind {
            context.fill(
              Path(ellipseIn: CGRect(x: x(ranAt) - 4, y: size.height / 2 - 4, width: 8, height: 8)),
              with: .color(.orange))
          }
        }
      }
      .frame(width: width, height: Self.laneHeight)
      ForEach(model.sessions) { session in
        sessionLane(session)
          .frame(width: width, height: Self.rowHeight)
      }
    }
    .overlay(alignment: .topLeading) {
      Rectangle().fill(Color.accentColor).frame(width: 2)
        .offset(x: x(model.cursor))
        .allowsHitTesting(false)
    }
    .contentShape(Rectangle())
    .gesture(
      DragGesture(minimumDistance: 0).onChanged { value in
        let seconds = Double(value.location.x) / dayWidth * 86_400
        model.cursor = min(model.start.addingTimeInterval(max(seconds, 0)), model.end)
      })
    .accessibilityHidden(true)
  }

  private func sessionLane(_ session: BenchSession) -> some View {
    let archival = model.outcome.archivals[session.id]
    return Canvas { context, size in
      let band = CGRect(x: 0, y: size.height / 2 - 7, width: size.width, height: 14)
      var entries = session.history.filter { $0.date <= model.end }
      if let archival {
        entries = entries.filter { $0.date < archival.date }
        entries.append(SessionStatusChange(date: archival.date, from: nil, to: .archived, cause: .user))
      }
      for (index, entry) in entries.enumerated() {
        let from = x(max(entry.date, model.start))
        let to = index + 1 < entries.count ? x(entries[index + 1].date) : size.width
        guard to > from else { continue }
        let rect = CGRect(x: from, y: band.minY, width: to - from, height: band.height)
        context.fill(Path(rect), with: .color(Self.color(of: entry.to)))
        if entry.date >= model.start, entry.date <= model.end {
          context.fill(
            Path(ellipseIn: CGRect(x: from - 3, y: band.minY - 7, width: 6, height: 6)),
            with: .color(.primary.opacity(0.6)))
        }
      }
      if let until = session.runningUntil, until > model.start {
        let rect = CGRect(x: 0, y: band.maxY + 3, width: x(until), height: 4)
        context.fill(Path(rect), with: .color(.blue.opacity(0.6)))
      }
      for skip in model.outcome.skips[session.id] ?? [] {
        context.stroke(
          Path(ellipseIn: CGRect(x: x(skip.date) - 5, y: band.midY - 5, width: 10, height: 10)),
          with: .color(.orange), lineWidth: 2)
      }
      if let archival {
        context.fill(
          Path(roundedRect: CGRect(x: x(archival.date) - 6, y: band.midY - 6, width: 12, height: 12), cornerRadius: 3),
          with: .color(Self.ruleColor(archival.ruleIndex)))
      }
    }
  }

  static func color(of status: SessionTaskStatus) -> Color {
    status == .archived ? Color.gray.opacity(0.35) : status.tint.opacity(0.55)
  }

  static func ruleColor(_ index: Int) -> Color {
    [Color.red, .green, .blue, .purple, .orange, .teal, .pink][index % 7]
  }
}

/// Changes a made-up session: its colour, its column, when it was done, what runs in it.
private struct BenchSessionEditor: View {
  @Bindable var model: ArchiveRuleBenchModel
  let id: SessionID

  private var index: Int? { model.sessions.firstIndex { $0.id == id } }

  var body: some View {
    if let index {
      Form {
        TextField(text: $model.sessions[index].name) {
          Text("Name", bundle: .module, comment: "A field of a made-up session of the test bench.")
        }
        TextField(text: $model.sessions[index].colorHex) {
          Text("Badge colour", bundle: .module, comment: "A field of a made-up session: #RRGGBB.")
        }
        Toggle(isOn: $model.sessions[index].showsProjectIcon) {
          Text("Shows the project's icon", bundle: .module, comment: "A field of a made-up session.")
        }
        TextField(
          text: Binding(
            get: { model.sessions[index].project ?? "" },
            set: { model.sessions[index].project = $0.isEmpty ? nil : $0 })
        ) {
          Text("Group", bundle: .module, comment: "A field of a made-up session.")
        }
        Toggle(isOn: $model.sessions[index].isDirty) {
          Text("Its folder has changes", bundle: .module, comment: "A field of a made-up session.")
        }
        Toggle(
          isOn: Binding(
            get: { model.sessions[index].runningUntil != nil },
            set: { on in
              model.sessions[index].runningUntil =
                on ? model.calendar.date(byAdding: .day, value: 7, to: model.start) : nil
            })
        ) {
          Text("Something runs in it", bundle: .module, comment: "A field of a made-up session.")
        }
        if let until = model.sessions[index].runningUntil {
          DatePicker(
            selection: Binding(get: { until }, set: { model.sessions[index].runningUntil = $0 })
          ) {
            Text("Until", bundle: .module, comment: "When what runs in a made-up session stops.")
          }
        }
        Picker(
          selection: Binding(
            get: { model.sessions[index].status(at: model.cursor) },
            set: { model.sessions[index].move(to: $0, at: model.cursor) })
        ) {
          ForEach(SessionTaskStatus.allCases, id: \.self) { status in
            Text(status.label).tag(status)
          }
        } label: {
          Text("Column at the cursor", bundle: .module, comment: "A field of a made-up session: moves it on the cursor's day.")
        }
        Button {
          // Archived by hand an hour before, and brought back now.
          model.sessions[index].move(
            to: .archived, at: model.cursor.addingTimeInterval(-3600), cause: .user)
          model.sessions[index].move(to: .done, at: model.cursor, cause: .unarchive)
        } label: {
          Text("Unarchived by you at the cursor", bundle: .module, comment: "Adds an event to a made-up session.")
        }
        HStack {
          Button {
            model.duplicate(model.sessions[index])
          } label: {
            Text("Duplicate", bundle: .module, comment: "Copies a made-up session of the test bench.")
          }
          Button(role: .destructive) {
            model.remove(model.sessions[index])
          } label: {
            Text("Remove", bundle: .module, comment: "Removes a made-up session of the test bench.")
          }
        }
      }
      .formStyle(.grouped)
      .frame(width: 380)
    }
  }
}

extension Color {
  /// `#RRGGBB`, or grey.
  init(hex: String) {
    let value = Int(hex.dropFirst().prefix(6), radix: 16) ?? 0x8E8E96
    self.init(
      red: Double((value >> 16) & 0xFF) / 255, green: Double((value >> 8) & 0xFF) / 255,
      blue: Double(value & 0xFF) / 255)
  }
}

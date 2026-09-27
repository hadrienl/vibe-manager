import SwiftUI
import UniformTypeIdentifiers
import VibeApplication
import VibeDomain

/// What a drag over a session shows while it hovers (#42).
enum DropHover: Equatable {
  case accepting(SessionDropRoute)
  case refusing(SessionDropRefusal)

  var isRefusing: Bool {
    if case .refusing = self { return true }
    return false
  }
}

/// The session's terminal and conversation, as one place to drop files on (#42).
///
/// On the column rather than on each view: SwiftTerm registers no dragged type, so the terminal
/// lets the drag through to here, and the conversation is dropped on over all of its surface.
struct SessionDropZone: ViewModifier {
  let model: AppModel
  let sessionID: SessionID
  @State private var hover: DropHover?

  func body(content: Content) -> some View {
    content
      .overlay {
        if let hover {
          DropHoverOverlay(hover: hover)
        }
      }
      .onDrop(
        of: DropReader.acceptedTypes,
        delegate: SessionDropDelegate(model: model, sessionID: sessionID, hover: $hover)
      )
      .clearsWhenDragEnds(hover != nil) { hover = nil }
      // The zone wraps every session's pane and keeps its identity from one to the next: a hover
      // left over must not follow to the session shown next.
      .onChange(of: sessionID) { hover = nil }
  }
}

/// A drag in progress is a mouse button held down. SwiftUI does not always tell a drop delegate
/// that the drag left or ended — a text view under the pointer takes it over, the views change
/// under it — and an overlay drawn for the hover then stays on screen for good. Once the button
/// is up, no drag can still be hovering, whatever the delegate was told.
@MainActor
enum DragEndWatch {
  static let interval: Duration = .milliseconds(250)

  static func isButtonDown() -> Bool { NSEvent.pressedMouseButtons & 1 != 0 }

  /// Returns once the button is released, or throws when cancelled.
  static func waitForRelease(
    interval: Duration = DragEndWatch.interval,
    isButtonDown: () -> Bool = { DragEndWatch.isButtonDown() },
    sleep: (Duration) async throws -> Void = { try await Task.sleep(for: $0) }
  ) async throws {
    repeat {
      try await sleep(interval)
    } while isButtonDown()
  }
}

extension View {
  /// Calls `clear` when the drag behind a hover ends without its delegate hearing of it.
  func clearsWhenDragEnds(_ isHovering: Bool, clear: @escaping @MainActor () -> Void) -> some View {
    task(id: isHovering) {
      guard isHovering else { return }
      do { try await DragEndWatch.waitForRelease() } catch { return }
      clear()
    }
  }
}

struct SessionDropDelegate: DropDelegate {
  let model: AppModel
  let sessionID: SessionID
  @Binding var hover: DropHover?

  func dropEntered(info: DropInfo) {
    hover = Self.hover(
      for: model.dropRoute(for: sessionID), isButtonDown: DragEndWatch.isButtonDown())
  }

  func dropUpdated(info: DropInfo) -> DropProposal? {
    let route = model.dropRoute(for: sessionID)
    hover = Self.hover(for: route, isButtonDown: DragEndWatch.isButtonDown())
    // No "+" on the pointer: the refusal is seen before letting go.
    return DropProposal(operation: route.isRefused ? .forbidden : .copy)
  }

  func dropExited(info: DropInfo) {
    hover = nil
  }

  func performDrop(info: DropInfo) -> Bool {
    hover = nil
    guard !model.dropRoute(for: sessionID).isRefused else { return false }
    let providers = info.itemProviders(for: DropReader.acceptedTypes)
    let model = model
    let id = sessionID
    Task { await model.deliverDrop(providers, to: id) }
    return true
  }

  static func hover(for route: SessionDropRoute) -> DropHover {
    if case .refused(let refusal) = route { return .refusing(refusal) }
    return .accepting(route)
  }

  /// No hover once the button is up. SwiftUI calls the delegate again after the drop, while the
  /// file just attached moves the views under the dragged image: the zone came back on screen
  /// after being cleared, and nothing cleared it a second time.
  static func hover(for route: SessionDropRoute, isButtonDown: Bool) -> DropHover? {
    isButtonDown ? hover(for: route) : nil
  }
}

/// The veil over the session while a drag hovers: the accent where it will be taken, red where it
/// will not, and a sentence either way.
struct DropHoverOverlay: View {
  let hover: DropHover
  @Environment(\.colorSchemeContrast) private var contrast

  var body: some View {
    let color = hover.isRefusing ? Color.red : Color.accentColor
    RoundedRectangle(cornerRadius: 12)
      .stroke(
        color,
        style: StrokeStyle(lineWidth: 2, dash: contrast == .increased ? [] : [6, 4])
      )
      .background(color.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
      .overlay {
        Label {
          Text(message)
        } icon: {
          Image(systemName: hover.isRefusing ? "nosign" : "square.and.arrow.down")
        }
        .font(.system(size: 15, weight: .semibold))
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(.regularMaterial, in: Capsule())
      }
      .padding(14)
      .allowsHitTesting(false)
      .accessibilityHidden(true)
  }

  private var message: String {
    switch hover {
    case .accepting(.conversation):
      String(localized: "Drop to attach to your message", bundle: .module)
    case .accepting:
      String(localized: "Drop to type the paths in the terminal", bundle: .module)
    case .refusing(.stopped):
      String(localized: "The session is stopped", bundle: .module)
    case .refusing(.archived):
      String(localized: "The session is archived", bundle: .module)
    }
  }
}

/// What the last drop on the session on screen had to say, at the foot of the column.
struct DropNoticeBar: View {
  let notice: SessionDropNotice
  let allowFullDiskAccess: () -> Void
  let dismiss: () -> Void

  var body: some View {
    HStack(alignment: .firstTextBaseline, spacing: 10) {
      Image(systemName: notice.offersFullDiskAccess ? "lock" : "info.circle")
        .foregroundStyle(.secondary)
      VStack(alignment: .leading, spacing: 4) {
        ForEach(notice.messages, id: \.self) { message in
          Text(verbatim: message)
            .fixedSize(horizontal: false, vertical: true)
        }
      }
      Spacer(minLength: 8)
      if notice.offersFullDiskAccess {
        Button(action: allowFullDiskAccess) {
          Text("Allow Full Disk Access…", bundle: .module)
        }
      }
      Button(action: dismiss) {
        Image(systemName: "xmark")
      }
      .buttonStyle(.borderless)
      .accessibilityLabel(Text("Dismiss", bundle: .module))
    }
    .font(.callout)
    .padding(.horizontal, 14)
    .padding(.vertical, 10)
    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
    .overlay(RoundedRectangle(cornerRadius: 10).stroke(.separator))
    .padding(12)
    .frame(maxWidth: 640)
  }
}

/// Selects a session whose row a drag rests on (#42), as the Finder opens a folder: its terminal
/// or its conversation comes forward, and the drop goes where the user lets go.
@MainActor
final class SpringLoading {
  static let delay: Duration = .milliseconds(800)

  private let delay: Duration
  private let sleep: @Sendable (Duration) async throws -> Void
  private var pending: (id: SessionID, task: Task<Void, Never>)?

  init(
    delay: Duration = SpringLoading.delay,
    sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }
  ) {
    self.delay = delay
    self.sleep = sleep
  }

  /// The drag is over `id`: `fire` runs once it has rested there for the delay. Moving to another
  /// row starts again.
  func enter(_ id: SessionID, fire: @escaping @MainActor () -> Void) {
    guard pending?.id != id else { return }
    pending?.task.cancel()
    let sleep = sleep
    let delay = delay
    pending = (
      id,
      Task { @MainActor [weak self] in
        do { try await sleep(delay) } catch { return }
        guard !Task.isCancelled, self?.pending?.id == id else { return }
        self?.pending = nil
        fire()
      }
    )
  }

  func exit(_ id: SessionID) {
    guard pending?.id == id else { return }
    pending?.task.cancel()
    pending = nil
  }

  /// Whatever row the drag was over: the drag is over.
  func cancel() {
    pending?.task.cancel()
    pending = nil
  }
}

/// A drop on a row of the sidebar: the session is selected, then receives it. A drag that rests
/// on the row selects it first.
struct SessionRowDropDelegate: DropDelegate {
  let model: AppModel
  let sessionID: SessionID
  let springLoading: SpringLoading
  @Binding var hovered: DropHover?

  func dropEntered(info: DropInfo) {
    track(model.dropRoute(for: sessionID))
  }

  func dropUpdated(info: DropInfo) -> DropProposal? {
    let route = model.dropRoute(for: sessionID)
    // On every move too: the watch on the button may have cleared the outline, and put the row's
    // spring away, under a drag that was still going on.
    track(route)
    return DropProposal(operation: route.isRefused ? .forbidden : .copy)
  }

  /// Outlines the row and, for a drop it takes, arms its spring — once: arming it again for the
  /// same row leaves the delay running. Without a hover, the spring is put away.
  private func track(_ route: SessionDropRoute) {
    let hover = SessionDropDelegate.hover(for: route, isButtonDown: DragEndWatch.isButtonDown())
    if hovered != hover { hovered = hover }
    guard hover != nil, !route.isRefused else {
      // Called once the button is up, or over a refused row: nothing may open it any more. The
      // sidebar's watch would not do it — the outline cleared here is what stops that watch.
      springLoading.exit(sessionID)
      return
    }
    let model = model
    let id = sessionID
    springLoading.enter(id) {
      guard model.selectedSessionID != id else { return }
      model.select(id)
    }
  }

  func dropExited(info: DropInfo) {
    hovered = nil
    springLoading.exit(sessionID)
  }

  func performDrop(info: DropInfo) -> Bool {
    hovered = nil
    springLoading.exit(sessionID)
    guard !model.dropRoute(for: sessionID).isRefused else { return false }
    let providers = info.itemProviders(for: DropReader.acceptedTypes)
    let model = model
    let id = sessionID
    model.select(id)
    Task { await model.deliverDrop(providers, to: id) }
    return true
  }
}

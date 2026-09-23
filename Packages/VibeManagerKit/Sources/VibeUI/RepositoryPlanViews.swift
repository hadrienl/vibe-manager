import AppKit
import SwiftUI
import VibeApplication
import VibeDomain

/// What a resolution does to the draft of one repository, once the user has picked it.
///
/// Most resolutions are a change of that repository's own choices; the others need something only
/// the caller can do — opening the panel, taking the repository out, renaming the session.
enum RepositoryResolutionEffect: Equatable {
  case applied
  case chooseAnotherFolder
  case remove
  case changeSlug(String)
}

extension SessionDraftRepository {
  mutating func apply(_ resolution: RepositoryResolution) -> RepositoryResolutionEffect {
    switch resolution {
    case .keepAsPlainFolder:
      mode = .plainFolder
    case .chooseAnotherFolder:
      return .chooseAnotherFolder
    case .remove:
      return .remove
    case .changeSlug(let suggestion):
      return .changeSlug(suggestion)
    case .useExistingBranch:
      choice = .useExistingBranch
    case .adoptWorktree(let path):
      choice = .adoptWorktree(path: path)
    case .chooseAnotherSubfolder(let suggestion):
      subfolderName = suggestion
    case .switchToWorktree:
      mode = .worktree
      choice = nil
    case .createBranchInPlace:
      choice = .createBranchInPlace
    }
    return .applied
  }
}

/// Paths are shown the way the user types them.
func abbreviatedPath(_ path: String) -> String {
  (path as NSString).abbreviatingWithTildeInPath
}

/// The plan of one repository: where it will be worked in, on which branch, from what.
struct RepositoryPlanSummary: View {
  let plan: RepositoryPlan

  var body: some View {
    VStack(alignment: .leading, spacing: 3) {
      switch plan.action {
      case .createWorktree(let createsBranch):
        if let path = plan.worktreePath {
          Label(abbreviatedPath(path), systemImage: "arrow.turn.down.right")
            .help(path)
        }
        Label(
          branchLine(createsBranch: createsBranch),
          systemImage: "arrow.triangle.branch"
        )
      case .adoptWorktree:
        if let path = plan.worktreePath {
          Label("Works in the existing \(abbreviatedPath(path))", systemImage: "checkmark.circle")
            .help(path)
        }
        if let branch = plan.branchName {
          Label(branch, systemImage: "arrow.triangle.branch")
        }
      case .inPlace(let createsBranch):
        Label("Works in the clone itself", systemImage: "folder")
        Label(
          createsBranch
            ? "Creates \(plan.branchName ?? "the session branch") here"
            : (plan.branchName.map { "Stays on \($0)" } ?? "Detached HEAD"),
          systemImage: "arrow.triangle.branch"
        )
      case .plainFolder:
        Label("A plain folder: no branch, no worktree", systemImage: "folder")
      case .blocked:
        Label("Not prepared until the conflict below is resolved", systemImage: "pause.circle")
      }
    }
    .font(.caption)
    .foregroundStyle(.secondary)
    .lineLimit(1)
    .truncationMode(.middle)
  }

  private func branchLine(createsBranch: Bool) -> String {
    let branch = plan.branchName ?? "the session branch"
    guard createsBranch else { return "On the existing \(branch)" }
    guard let base = plan.baseLabel else { return "New branch \(branch)" }
    return "New branch \(branch), from \(base)"
  }
}

/// A conflict, its remedy, the command to copy when there is one, and the gestures it proposes.
struct RepositoryIssueRow: View {
  let issue: RepositoryAttachmentIssue
  let resolve: (RepositoryResolution) -> Void
  var hiddenResolutions: (RepositoryResolution) -> Bool = { _ in false }

  var body: some View {
    VStack(alignment: .leading, spacing: 5) {
      HStack(alignment: .firstTextBaseline, spacing: 5) {
        Image(systemName: symbol)
          .foregroundStyle(color)
        Text("\(issue.message) \(issue.remedy)")
          .fixedSize(horizontal: false, vertical: true)
      }
      .font(.caption)
      .accessibilityElement(children: .combine)

      if let command = issue.command {
        CopyableCommand(command: command)
      }

      let offered = issue.resolutions.filter { !hiddenResolutions($0) }
      if !offered.isEmpty {
        HStack(spacing: 6) {
          ForEach(offered) { resolution in
            Button(resolution.title) { resolve(resolution) }
              .controlSize(.small)
          }
        }
      }
    }
  }

  private var symbol: String {
    switch issue.severity {
    case .blocking: return "exclamationmark.circle.fill"
    case .warning: return "exclamationmark.triangle.fill"
    case .notice: return "info.circle"
    }
  }

  private var color: Color {
    switch issue.severity {
    case .blocking: return .red
    case .warning: return .orange
    case .notice: return .secondary
    }
  }
}

/// A shell command, selectable and copyable, never run.
struct CopyableCommand: View {
  let command: String

  var body: some View {
    HStack(alignment: .top, spacing: 6) {
      Text(command)
        .font(.system(.caption, design: .monospaced))
        .textSelection(.enabled)
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity, alignment: .leading)
      Button {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(command, forType: .string)
      } label: {
        Image(systemName: "doc.on.doc")
      }
      .buttonStyle(.borderless)
      .help("Copy the command")
      .accessibilityLabel("Copy the command")
    }
    .padding(6)
    .background(RoundedRectangle(cornerRadius: 5).fill(.quaternary))
  }
}

/// Opens the panel on a folder and hands the chosen one back. The panel is what grants access to
/// it, which is why a folder is only ever designated through it.
@MainActor
func chooseFolder(startingAt path: String?, prompt: String = "Choose") -> String? {
  let panel = NSOpenPanel()
  panel.canChooseDirectories = true
  panel.canChooseFiles = false
  panel.allowsMultipleSelection = false
  panel.canCreateDirectories = true
  panel.prompt = prompt
  panel.directoryURL = URL(fileURLWithPath: path ?? NSHomeDirectory(), isDirectory: true)
  guard panel.runModal() == .OK, let url = panel.url else { return nil }
  return url.path
}

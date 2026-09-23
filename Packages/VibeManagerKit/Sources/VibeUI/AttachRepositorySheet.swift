import SwiftUI
import VibeApplication
import VibeDomain

/// One more repository for a session: what it is, what will be done to it, and a confirmation.
struct AttachRepositorySheet: View {
  let model: RepositoryAttachmentModel
  let attach: () -> Void
  let cancel: () -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 14) {
      VStack(alignment: .leading, spacing: 3) {
        Text("Attach a Repository")
          .font(.title2.weight(.semibold))
        Text("to “\(model.sessionName)”. Nothing is written until you confirm.")
          .font(.caption)
          .foregroundStyle(.secondary)
      }

      if let repository = model.repository {
        VStack(alignment: .leading, spacing: 8) {
          Label(
            abbreviatedPath(repository.resolvedPath ?? repository.path),
            systemImage: "folder"
          )
          .lineLimit(1)
          .truncationMode(.middle)

          if let plan = model.plan {
            if plan.mode != .plainFolder, plan.commonDirectory != nil {
              HStack(spacing: 10) {
                Picker("Mode", selection: modeBinding(plan)) {
                  Text("Worktree").tag(RepositoryAttachmentMode.worktree)
                  Text("In place").tag(RepositoryAttachmentMode.inPlace)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 180)
                if plan.mode == .worktree {
                  Picker("Base", selection: baseBinding(repository)) {
                    Text("From HEAD").tag(RepositoryBase.head)
                    Text("From the default branch").tag(RepositoryBase.defaultBranch)
                  }
                  .labelsHidden()
                  .frame(maxWidth: 220)
                }
              }
            }
            RepositoryPlanSummary(plan: plan)
            ForEach(plan.issues) { issue in
              RepositoryIssueRow(
                issue: issue,
                resolve: resolve,
                hiddenResolutions: { !RepositoryAttachmentModel.isOffered($0) }
              )
            }
          } else {
            ProgressView()
              .controlSize(.small)
          }
        }
        .padding(10)
        .background(
          RoundedRectangle(cornerRadius: 8).strokeBorder(Color(nsColor: .separatorColor)))
      }

      if let failure = model.failure {
        Label(failure, systemImage: "exclamationmark.circle.fill")
          .font(.caption)
          .foregroundStyle(.red)
      }

      HStack {
        if model.plan?.isBlocked == true {
          Text("Resolve the conflict above to attach it.")
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        Spacer()
        Button("Cancel", role: .cancel, action: cancel)
          .keyboardShortcut(.cancelAction)
        Button(model.isWorking ? "Preparing…" : "Attach", action: attach)
          .keyboardShortcut(.defaultAction)
          .buttonStyle(.borderedProminent)
          .disabled(!model.canAttach)
      }
    }
    .padding(20)
    .frame(width: 560)
  }

  private func modeBinding(_ plan: RepositoryPlan) -> Binding<RepositoryAttachmentMode> {
    Binding(
      get: { plan.mode == .inPlace ? .inPlace : .worktree },
      set: { mode in Task { await model.setMode(mode) } }
    )
  }

  private func baseBinding(_ repository: SessionDraftRepository) -> Binding<RepositoryBase> {
    Binding(
      get: { repository.base },
      set: { base in Task { await model.setBase(base) } }
    )
  }

  private func resolve(_ resolution: RepositoryResolution) {
    Task {
      guard await model.resolve(resolution) == .chooseAnotherFolder else { return }
      let start = model.repository?.resolvedPath
      guard let path = chooseFolder(startingAt: start, prompt: "Attach") else { return }
      await model.folderChosen(path)
    }
  }
}

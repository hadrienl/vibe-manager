import AppKit
import SwiftUI
import VibeApplication
import VibeDomain

/// Settings › Add an Account (#478): the CLI, a name and a configuration folder.
struct NewAgentAccountPage: View {
  let accounts: AgentAccountsSettingsModel
  let show: (SettingsPage) -> Void
  @State private var harness = EndpointHarness.claudeCode
  @State private var name = "Claude 2"
  @State private var directory = "~/.claude-2"

  private var draft: AgentAccount {
    AgentAccount(name: name, harness: harness, configurationDirectory: directory)
  }

  private var issue: AgentAccount.ValidationIssue? { accounts.issues(of: draft).first }

  var body: some View {
    Form {
      Section {
        Picker(selection: $harness) {
          Text(verbatim: "Claude Code").tag(EndpointHarness.claudeCode)
          Text(verbatim: "Codex").tag(EndpointHarness.codex)
        } label: {
          Text("Agent", bundle: .module)
        }
        .pickerStyle(.segmented)
        .onChange(of: harness) { _, new in
          name = new == .claudeCode ? "Claude 2" : "Codex 2"
          directory = new == .claudeCode ? "~/.claude-2" : "~/.codex-2"
        }
        TextField(text: $name) {
          Text("Name", bundle: .module)
        }
        LabeledContent {
          HStack {
            TextField(text: $directory) { EmptyView() }
              .labelsHidden()
              .font(.body.monospaced())
            Button {
              AgentAccountFolderPanel.choose { directory = $0 }
            } label: {
              Text("Choose…", bundle: .module)
            }
          }
        } label: {
          Text("Configuration Folder", bundle: .module)
          Text(verbatim: harness == .claudeCode ? "CLAUDE_CONFIG_DIR" : "CODEX_HOME")
            .font(.caption.monospaced())
        }
        if let issue {
          Label {
            Text(verbatim: Self.message(of: issue, harness: harness))
          } icon: {
            Image(systemName: "exclamationmark.triangle.fill")
          }
          .foregroundStyle(.red)
        }
      } footer: {
        Text(
          """
          The folder is created if needed. The account starts from nothing: it has neither the \
          MCP servers, the plugins nor the skills of the agent's own account.
          """, bundle: .module
        )
        .font(.caption)
        .foregroundStyle(.secondary)
      }
      if let error = accounts.storeError {
        Text(verbatim: error).foregroundStyle(.red)
      }
      Section {
        HStack {
          Spacer()
          Button {
            let account = draft
            Task {
              if await accounts.add(account) {
                show(.agent(AgentProviderID(account.providerID)))
              }
            }
          } label: {
            Text("Add", bundle: .module, comment: "Adds an account of an agent.")
          }
          .buttonStyle(.borderedProminent)
          .disabled(issue != nil)
        }
      }
    }
    .formStyle(.grouped)
    .task { await accounts.load() }
  }

  static func message(of issue: AgentAccount.ValidationIssue, harness: EndpointHarness) -> String {
    switch issue {
    case .noName:
      String(localized: "Give this account a name.", bundle: .module)
    case .directoryNotAbsolute:
      String(localized: "Enter an absolute path, or one starting with ~/.", bundle: .module)
    case .directoryIsDefault:
      String(
        localized: "This is the folder of \(harness == .claudeCode ? "Claude Code" : "Codex"). Choose another one.",
        bundle: .module, comment: "An agent's name.")
    case .directoryTaken(let name):
      String(
        localized: "This folder is already the account \(name)’s.", bundle: .module,
        comment: "The name of an account of an agent.")
    }
  }
}

/// A folder chosen in a sheet of the settings window: the window stays in front (#432).
enum AgentAccountFolderPanel {
  @MainActor static func choose(_ chosen: @escaping (String) -> Void) {
    let panel = NSOpenPanel()
    panel.canChooseDirectories = true
    panel.canChooseFiles = false
    panel.canCreateDirectories = true
    panel.showsHiddenFiles = true
    let finish: (NSApplication.ModalResponse) -> Void = { response in
      if response == .OK, let url = panel.url { chosen(url.path) }
    }
    if let window = NSApp.keyWindow {
      panel.beginSheetModal(for: window, completionHandler: finish)
    } else {
      panel.begin(completionHandler: finish)
    }
  }
}

/// On an agent's page: its signed in account, the sign-in, and for an extra account (#478) its
/// name, folder and removal.
struct AgentAccountSections: View {
  let model: AppModel
  let agent: AgentDescriptor
  @State private var isConfirmingDelete = false
  @State private var editedName: String?

  private var account: AgentAccount? {
    model.agentAccounts?.accounts.first { $0.providerID == agent.id.rawValue }
  }

  private var state: AgentAvailabilityState? {
    model.agentDiagnostics.first { $0.providerID == agent.id }?.state
  }

  var body: some View {
    Group {
      if let account {
        Section {
          TextField(
            text: Binding(
              get: { editedName ?? account.name }, set: { editedName = $0 })
          ) {
            Text("Name", bundle: .module)
          }
          .onSubmit { rename(account) }
          LabeledContent {
            Text(verbatim: account.configurationDirectory)
              .font(.body.monospaced())
              .textSelection(.enabled)
          } label: {
            Text("Configuration Folder", bundle: .module)
          }
        }
      }
      signIn
      if let account {
        Section {
          HStack {
            Spacer()
            Button(role: .destructive) {
              isConfirmingDelete = true
            } label: {
              Text("Delete Account…", bundle: .module)
            }
          }
        }
        .confirmationDialog(
          Text("Delete “\(account.name)”?", bundle: .module), isPresented: $isConfirmingDelete
        ) {
          Button(role: .destructive) {
            Task {
              model.signedInAccounts.remember(nil, of: agent.id)
              await model.agentAccounts?.delete(account.id)
              model.settingsPage = .newAccount
            }
          } label: {
            Text("Delete", bundle: .module)
          }
        } message: {
          Text(
            "The agent leaves the list, and its sessions can no longer be read or resumed here, even if the folder is added again. The folder and its conversations stay on the disk.",
            bundle: .module)
        }
      }
    }
    .task {
      await model.agentAccounts?.load()
      await model.loadSigningAgents()
    }
    .onDisappear { if let account { rename(account) } }
  }

  private func rename(_ account: AgentAccount) {
    guard let name = editedName, name != account.name else { return }
    editedName = nil
    Task { await model.agentAccounts?.rename(account.id, to: name) }
  }

  /// Nothing for an agent that does not sign in by itself, or when there is nothing to say.
  @ViewBuilder
  private var signIn: some View {
    let progress = model.signIns[agent.id]
    let address = model.signedInAddresses[agent.id]
    let isSignedOut = state == .unauthenticated
    if address != nil || isSignedOut || progress != nil || model.agentsSigningIn.contains(agent.id) {
      Section {
        if let address {
          LabeledContent {
            Text(verbatim: address).textSelection(.enabled)
          } label: {
            Text("Account", bundle: .module, comment: "The account an agent is signed in to.")
          }
        }
        switch progress {
        case .running?:
          HStack {
            ProgressView().controlSize(.small)
            Text(
              "Signing in to \(agent.displayName) in the browser…", bundle: .module,
              comment: "An agent's name.")
            Spacer()
            Button {
              model.cancelSignIn(agent: agent.id)
            } label: {
              Text("Cancel", bundle: .module)
            }
          }
        case .otherAccount(let expected, let actual)?:
          Text(
            "\(agent.displayName) is now signed in to \(actual), not \(expected).",
            bundle: .module, comment: "An agent's name, then two email addresses.")
          HStack {
            Spacer()
            Button {
              model.signIn(agent: agent.id)
            } label: {
              Text("Sign In Again", bundle: .module)
            }
            Button {
              model.keepSignedInAccount(of: agent.id)
            } label: {
              Text("Keep This Account", bundle: .module)
            }
          }
        case .failed(let detail, _)?:
          if let detail { Text(verbatim: detail).foregroundStyle(.secondary) }
          signInButton
        case nil:
          if isSignedOut {
            signInButton
          } else if model.agentsSigningIn.contains(agent.id) {
            HStack {
              Spacer()
              Button {
                model.signIn(agent: agent.id)
              } label: {
                Text("Sign In Again", bundle: .module)
              }
            }
          }
        }
      } footer: {
        if isSignedOut, progress == nil,
          let command = model.agentDiagnostics.first(where: { $0.providerID == agent.id })?
            .remediations.lazy.compactMap(\.command).first
        {
          Text(verbatim: command)
            .font(.caption.monospaced())
            .foregroundStyle(.secondary)
            .textSelection(.enabled)
        }
      }
    }
  }

  private var signInButton: some View {
    HStack {
      Spacer()
      Button {
        model.signIn(agent: agent.id)
      } label: {
        Text("Sign In", bundle: .module)
      }
      .buttonStyle(.borderedProminent)
    }
  }
}

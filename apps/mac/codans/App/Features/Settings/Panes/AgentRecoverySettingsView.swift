import CodansCore
import SwiftUI

struct AgentRecoverySettingsView: View {
  @Environment(SettingsStore.self) private var settingsStore

  private var policy: AgentRecoveryPolicy {
    settingsStore.settings.agents.recovery
  }

  var body: some View {
    Section {
      Toggle("Enable Automatic Recovery", isOn: binding(\.isEnabled))
      if policy.isEnabled {
        Picker("Action", selection: binding(\.action)) {
          Text("Send Prompt").tag(AgentRecoveryPolicy.Action.prompt)
          Text("Run Script").tag(AgentRecoveryPolicy.Action.script)
        }
        if policy.action == .prompt {
          VStack(alignment: .leading, spacing: 8) {
            Text("Recovery Prompt")
            PlainCommandEditor(text: binding(\.prompt))
              .frame(height: 72)
              .accessibilityLabel("Recovery prompt")
          }
        } else {
          VStack(alignment: .leading, spacing: 8) {
            Text("Recovery Script")
            PlainCommandEditor(text: binding(\.script))
              .frame(height: 96)
              .accessibilityLabel("Recovery script")
            Text(
              "Runs in the worktree directory using /bin/zsh -lc. "
                + "The script runs separately from the agent and does not send a follow-up prompt."
            )
            .font(.caption)
            .foregroundStyle(.secondary)
          }
        }
        if policy.action == .script {
          ForEach([AgentFailure.Reason.authentication, .quotaExceeded, .configuration, .unknown], id: \.self) {
            reason in
            Toggle(
              "Also Handle \(reasonLabel(reason))",
              isOn: Binding(
                get: { policy.additionalScriptReasons.contains(reason) },
                set: { enabled in
                  settingsStore.mutateAgents {
                    if enabled {
                      $0.recovery.additionalScriptReasons.insert(reason)
                    } else {
                      $0.recovery.additionalScriptReasons.remove(reason)
                    }
                  }
                }
              ))
          }
        }
        Stepper("Retry Delay: \(policy.delaySeconds) seconds", value: binding(\.delaySeconds), in: 5...3600)
        Stepper("Maximum Attempts: \(policy.maxAttempts)", value: binding(\.maxAttempts), in: 1...10)
        if !policy.isValid {
          Text("Enter a non-empty prompt or script, a delay of 5–3600 seconds, and 1–10 attempts.")
            .font(.caption)
            .foregroundStyle(.red)
        }
      }
    } header: {
      Text("Error Recovery")
    } footer: {
      Text(
        "Off by default. Retries recognized temporary failures and rate limits in local agents. "
          + "Recovery stops when the agent resumes work, you interact with the session, "
          + "or the attempt limit is reached. Typing starts a new attempt budget. "
          + "Use the error row’s context menu to cancel recovery. Remote sessions are excluded."
      )
    }
  }

  private func reasonLabel(_ reason: AgentFailure.Reason) -> String {
    switch reason {
    case .authentication: return "Authentication Errors"
    case .quotaExceeded: return "Quota Errors"
    case .configuration: return "Configuration Errors"
    case .unknown: return "Unknown Errors"
    case .transient: return "Temporary Errors"
    case .rateLimited: return "Rate Limits"
    }
  }

  private func binding<Value>(
    _ keyPath: WritableKeyPath<AgentRecoveryPolicy, Value>
  ) -> Binding<Value> {
    Binding(
      get: { policy[keyPath: keyPath] },
      set: { value in
        settingsStore.mutateAgents { $0.recovery[keyPath: keyPath] = value }
      }
    )
  }
}

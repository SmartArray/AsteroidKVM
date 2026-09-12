// Group conversation preferences in a native popover so the composer stays compact and readable.
import CometAgent
import SwiftUI

struct AgentOptionsPopover: View {
  @ObservedObject var agent: AgentController
  @Binding var clickPreviewsEnabled: Bool

  // Changing preferences retains the controller's existing stop-and-restart semantics and local persistence.
  var body: some View {
    VStack(alignment: .leading, spacing: 14) {
      Text("Agent options").font(.headline)

      // Populate model choices from Codex itself so Luna and future image-capable models use valid identifiers.
      Picker(
        "Model",
        selection: Binding(
          get: { agent.selectedModel },
          set: { model in
            agent.selectModel(model)
            UserDefaults.standard.set(model, forKey: "agentModel")
            UserDefaults.standard.set(agent.selectedThinkingLevel, forKey: "agentThinkingLevel")
          })
      ) {
        Text("Codex default").tag("")
        ForEach(agent.models) { model in Text(model.name).tag(model.id) }
        if !agent.selectedModel.isEmpty
          && !agent.models.contains(where: { $0.id == agent.selectedModel })
        {
          Text(agent.selectedModel).tag(agent.selectedModel)
        }
      }
      .disabled(agent.loadingModels)
      .accessibilityIdentifier("agent-model-selector")
      .help("Changing models starts a new Codex conversation. Visible chat history is kept.")
      if let error = agent.modelListError {
        Text("Could not load models: \(error) Refresh the model list to retry.")
          .font(.caption).foregroundStyle(.secondary)
      }

      // Expose only runtime-supported effort levels and persist the preference without editing Codex configuration.
      Picker(
        "Thinking",
        selection: Binding(
          get: {
            agent.thinkingLevels.contains(agent.selectedThinkingLevel)
              ? agent.selectedThinkingLevel : ""
          },
          set: { level in
            agent.selectThinkingLevel(level)
            UserDefaults.standard.set(agent.selectedThinkingLevel, forKey: "agentThinkingLevel")
          })
      ) {
        Text("Automatic (\(agent.automaticThinkingLevel.capitalized))").tag("")
        ForEach(agent.thinkingLevels, id: \.self) { level in
          Text(level == "xhigh" ? "Extra High" : level.capitalized).tag(level)
        }
      }
      .disabled(agent.loadingModels || agent.thinkingLevels.isEmpty)
      .accessibilityIdentifier("agent-thinking-selector")
      .help(
        "Higher thinking levels can take longer. Changing the level starts a fresh Codex conversation."
      )

      // Permission changes stop the current turn; prompts cannot select or silently broaden this setting.
      Picker(
        "Remote permission",
        selection: Binding(get: { agent.controlMode }, set: { agent.setControlMode($0) })
      ) {
        ForEach(AgentControlMode.allCases, id: \.self) { mode in Text(mode.rawValue).tag(mode) }
      }.accessibilityIdentifier("agent-control-mode")
      if agent.controlMode == .fullControl {
        Text(
          "Full control allows unreviewed actions with the remote user's privileges, including deleting files or sending content."
        )
        .font(.caption).foregroundStyle(.orange)
      }

      // A single preview toggle controls the existing overlay and retains its persisted default-on behavior.
      Toggle("Show Click Preview", isOn: $clickPreviewsEnabled)
        .accessibilityIdentifier("agent-click-preview-toggle")
      Divider()
      Button("Refresh Models") { Task { await agent.refreshModels() } }
        .disabled(agent.loadingModels)
    }
    .padding(18).frame(width: 380)
  }
}

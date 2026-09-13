// Present a native, streaming conversation with persistent local controls and a compact action timeline.
import CometAgent
import CometSession
import SwiftUI

struct AgentChatView: View {
  @ObservedObject var agent: AgentController
  @ObservedObject var session: SessionController
  @State private var prompt = ""
  @State private var consent = false
  @State private var settingsOpen = false
  @State private var optionsOpen = false
  @State private var proposedURL: URL?
  @AppStorage("agentClickPreviewsEnabled") private var clickPreviewsEnabled = true
  @FocusState private var composerFocused: Bool

  // Starting explicitly grants this chat control and discloses that Codex receives the remote screen.
  var body: some View {
    VStack(spacing: 0) {
      HStack(spacing: 12) {
        Image(systemName: "sparkles").foregroundStyle(.tint)
        VStack(alignment: .leading, spacing: 3) {
          Text("Agent · Experimental").font(.headline)
          Text(session.profile.name).font(.caption).foregroundStyle(.secondary)
        }
        Spacer()
        Text(agent.status.rawValue).font(.caption).accessibilityIdentifier("agent-status")
        Button {
          if agent.status == .paused { agent.resume() } else { agent.pause() }
        } label: {
          Label(
            agent.status == .paused ? "Resume" : "Pause",
            systemImage: agent.status == .paused ? "play.fill" : "pause.fill")
        }
        .disabled(
          agent.status == .paused
            ? !agent.canResume : ![.running, .starting].contains(agent.status)
        )
        .accessibilityIdentifier("agent-pause")
        Button("Stop", systemImage: "stop.fill") { agent.stop() }
          .disabled(agent.status == .idle && agent.messages.isEmpty).accessibilityIdentifier(
            "agent-stop")
        Menu {
          Button("New Conversation") { agent.clear() }
          Button("Agent Settings…") { settingsOpen = true }
          Button("Refresh Models") { Task { await agent.refreshModels() } }
            .disabled(agent.loadingModels)
        } label: {
          Image(systemName: "ellipsis")
        }.menuIndicator(.hidden).fixedSize().accessibilityIdentifier("agent-menu")
      }.padding(16).background(.bar)
      Divider()
      ScrollViewReader { proxy in
        ScrollView {
          LazyVStack(alignment: .leading, spacing: 20) {
            if agent.messages.isEmpty {
              VStack(alignment: .leading, spacing: 14) {
                Text("What would you like to do?").font(.title2.bold())
                Text(
                  "Codex can read this Comet’s display, click, scroll, and type. Try creating a text document or navigating an application."
                ).foregroundStyle(.secondary)
                Button("Create a document with a poem about apples") {
                  prompt =
                    "Create a new text document and write a poem about apples. Leave it unsaved."
                  composerFocused = true
                }.buttonStyle(.link)
              }.padding(.vertical, 24)
            }
            ForEach(agent.messages) { message in AgentMessageView(message: message).id(message.id) }
            Color.clear.frame(height: 1).id("end")
          }.padding(24).frame(maxWidth: 760, alignment: .leading).frame(maxWidth: .infinity)
        }
        .onChange(of: agent.messages.last?.text) { _, _ in proxy.scrollTo("end", anchor: .bottom) }
      }
      Divider()
      VStack(alignment: .leading, spacing: 10) {
        // Render the exact immutable proposal beside its target before releasing the controller's input gate.
        if let approval = agent.pendingApproval {
          VStack(alignment: .leading, spacing: 8) {
            Text("Approve action on \(session.profile.host):\(session.profile.port)").font(
              .headline)
            // Short actions get their full intrinsic height; long typing proposals have a bounded readable viewport.
            if case .type = approval.action {
              ScrollView {
                approvalText(approval.action.reviewText)
              }.frame(height: 100)
            } else {
              approvalText(approval.action.reviewText)
            }
            Text(
              "Review the remote display. This approval expires 60 seconds after its screenshot."
            ).font(.caption)
            HStack {
              Button("Reject and Pause") { agent.rejectAction(id: approval.id) }
                .accessibilityIdentifier("agent-reject-action")
              Button("Approve This Action") { agent.approveAction(id: approval.id) }
                .buttonStyle(.borderedProminent).accessibilityIdentifier("agent-approve-action")
            }
          }.padding(12).background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
            .fixedSize(horizontal: false, vertical: true).layoutPriority(2)
        }

        Text(agent.detail).font(.caption).foregroundStyle(
          agent.status == .failed ? Color.orange : .secondary
        )
        .textSelection(.enabled).accessibilityIdentifier("agent-detail")
        if !consent {
          Toggle(
            "Allow remote control and send screenshots and chat to my Codex provider",
            isOn: $consent
          )
          .font(.caption).accessibilityIdentifier("agent-consent")
          Text(
            "Uses your Codex account and usage limits. Pause stops further input; a character already sent may finish. Activating the remote display window pauses the agent."
          )
          .font(.caption2).foregroundStyle(.secondary)
        }
        HStack(alignment: .bottom, spacing: 12) {
          TextEditor(text: $prompt).font(.body).scrollContentBackground(.hidden)
            .frame(height: agent.pendingApproval == nil ? 88 : 48).focused($composerFocused)
            .overlay(alignment: .topLeading) {
              if prompt.isEmpty {
                Text("Ask Codex to do something…").foregroundStyle(.tertiary).padding(.leading, 5)
                  .allowsHitTesting(false)
              }
            }.accessibilityIdentifier("agent-composer")
          Button("Send", systemImage: "arrow.up") { submit() }
            .labelStyle(.iconOnly).buttonStyle(.borderedProminent).controlSize(.large)
            .keyboardShortcut(.return, modifiers: .command)
            .disabled(
              !consent || prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                || prompt.count > 16000 || agent.status.busy || agent.status == .paused
                || !session.active
            )
            .accessibilityIdentifier("agent-send")
        }.padding(10).background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 12))
        // Keep chosen values visible beneath the draft while the full controls live in a native popover.
        HStack(spacing: 8) {
          Text(optionsSummary).font(.caption).foregroundStyle(.secondary)
            .lineLimit(1).truncationMode(.middle).help(optionsSummary)
            .accessibilityIdentifier("agent-options-summary")
          Spacer(minLength: 0)
          Button {
            optionsOpen.toggle()
          } label: {
            Image(systemName: "ellipsis").frame(width: 24, height: 20).contentShape(Rectangle())
          }
          .buttonStyle(.borderless).help("Agent options")
          .accessibilityLabel("Agent options").accessibilityIdentifier("agent-options")
          .popover(isPresented: $optionsOpen, arrowEdge: .bottom) {
            AgentOptionsPopover(agent: agent, clickPreviewsEnabled: $clickPreviewsEnabled)
          }
        }
        Text("⌘Return to send · Control stays with this Comet · Closing this chat pauses the agent")
          .font(.caption2).foregroundStyle(.secondary)
      }.padding(16).fixedSize(horizontal: false, vertical: true).layoutPriority(1)
    }
    .frame(minWidth: 520, minHeight: 540)
    .navigationTitle("Agent — \(session.profile.name)")
    .background(
      AgentWindowObserver { agent.pause(reason: "Paused because the agent chat was closed.") }
    )
    .sheet(isPresented: $settingsOpen) { AgentSettingsView() }
    // Loading model names sends no screenshots or prompts; the selected override stays local to this app.
    .task { await agent.refreshModels() }
    // Update the controller even during a pending approval so toggling the menu immediately changes the marker.
    .onChange(of: clickPreviewsEnabled, initial: true) { _, enabled in
      agent.setClickPreviewsEnabled(enabled)
    }
    .onDisappear { agent.pause(reason: "Paused because the agent chat was closed.") }
    // Screen-derived Markdown never invokes local URL handlers; even web links reveal their destination first.
    .environment(
      \.openURL,
      OpenURLAction { url in
        guard AgentLinkPolicy.allows(url) else { return .discarded }
        proposedURL = url
        return .handled
      }
    )
    .alert(
      "Open this website?",
      isPresented: Binding(get: { proposedURL != nil }, set: { if !$0 { proposedURL = nil } })
    ) {
      Button("Open in Browser") {
        if let url = proposedURL, AgentLinkPolicy.allows(url) { NSWorkspace.shared.open(url) }
        proposedURL = nil
      }
      Button("Cancel", role: .cancel) { proposedURL = nil }
    } message: {
      Text(proposedURL?.absoluteString ?? "")
    }
    .onChange(of: session.profile.agentIdentity) { _, _ in
      consent = false
      proposedURL = nil
    }
  }

  // Summarize the same bindings used by the popover, including the current permission and preview state.
  private var optionsSummary: String {
    let model =
      agent.selectedModel.isEmpty
      ? "Codex default" : agent.currentModel?.name ?? agent.selectedModel
    let level =
      agent.thinkingLevels.contains(agent.selectedThinkingLevel)
      ? agent.selectedThinkingLevel : agent.automaticThinkingLevel
    let thinking = level == "xhigh" ? "Extra High" : level.capitalized
    let preview = clickPreviewsEnabled ? "Preview on" : "Preview off"
    return "\(model) · \(thinking) thinking · \(agent.controlMode.rawValue) · \(preview)"
  }

  // Preserve readable, wrapping action text even when the transcript and composer compete for vertical space.
  private func approvalText(_ text: String) -> some View {
    Text(text).font(.system(.body, design: .monospaced)).foregroundStyle(.primary)
      .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
      .frame(maxWidth: .infinity, alignment: .leading)
      .accessibilityIdentifier("agent-approval-description")
  }

  // Consume the draft only after an explicit Send; chat text never reaches the local shell or clipboard.
  private func submit() {
    let text = prompt
    prompt = ""
    agent.send(text)
  }
}

// Render Markdown prose and fenced code separately so whitespace and copy operations stay predictable.
private struct AgentMessageView: View {
  let message: AgentMessage
  var body: some View {
    if message.kind == .action || message.kind == .notice {
      Label(message.text, systemImage: message.kind == .action ? "cursorarrow" : "info.circle")
        .font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
    } else {
      VStack(alignment: .leading, spacing: 10) {
        Text(message.kind == .user ? "You" : "Codex").font(.caption.bold()).foregroundStyle(
          .secondary)
        if message.kind == .user {
          Text(message.text).textSelection(.enabled)
        } else {
          let blocks = message.text.components(separatedBy: "```")
          ForEach(Array(blocks.enumerated()), id: \.offset) { index, block in
            if index.isMultiple(of: 2) {
              AgentMarkdownProse(text: block)
            } else {
              let code = block.components(separatedBy: "\n").dropFirst().joined(separator: "\n")
              VStack(alignment: .leading, spacing: 6) {
                HStack {
                  Text(block.components(separatedBy: "\n").first ?? "").font(.caption)
                    .foregroundStyle(.secondary)
                  Spacer()
                  Button("Copy") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(code, forType: .string)
                  }
                  .buttonStyle(.borderless).font(.caption)
                }
                ScrollView(.horizontal) {
                  Text(code).font(.system(.body, design: .monospaced)).textSelection(.enabled)
                }
              }.padding(12).background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
            }
          }
        }
      }.frame(maxWidth: .infinity, alignment: .leading)
    }
  }
}

// Render common block Markdown natively while leaving links, emphasis, and inline code to AttributedString.
private struct AgentMarkdownProse: View {
  let text: String

  var body: some View {
    VStack(alignment: .leading, spacing: 5) {
      ForEach(Array(text.components(separatedBy: "\n").enumerated()), id: \.offset) { _, line in
        if line.hasPrefix("### ") {
          prose(String(line.dropFirst(4))).font(.headline).padding(.top, 6)
        } else if line.hasPrefix("## ") {
          prose(String(line.dropFirst(3))).font(.title3.bold()).padding(.top, 8)
        } else if line.hasPrefix("# ") {
          prose(String(line.dropFirst(2))).font(.title2.bold()).padding(.top, 8)
        } else if line.hasPrefix("- ") || line.hasPrefix("* ") {
          HStack(alignment: .top, spacing: 8) {
            Text("•")
            prose(String(line.dropFirst(2)))
          }.padding(.leading, 6)
        } else if line.hasPrefix("> ") {
          HStack(spacing: 10) {
            Rectangle().fill(.secondary.opacity(0.4)).frame(width: 3)
            prose(String(line.dropFirst(2))).foregroundStyle(.secondary)
          }.fixedSize(horizontal: false, vertical: true)
        } else if line.trimmingCharacters(in: .whitespaces).isEmpty {
          Color.clear.frame(height: 5)
        } else {
          prose(line)
        }
      }
    }
  }

  // Preserve literal whitespace and let SwiftUI provide selectable text and accessible, explicit links.
  private func prose(_ value: String) -> some View {
    Text(
      (try? AttributedString(
        markdown: value, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
        ?? AttributedString(value)
    )
    .textSelection(.enabled)
  }
}

// Expose installation configuration without writing or displaying Codex authentication credentials.
private struct AgentSettingsView: View {
  @AppStorage("agentCodexPath") private var path = ""
  @Environment(\.dismiss) private var dismiss
  var body: some View {
    Form {
      Text("Agent Settings").font(.title2.bold())
      Text(
        "Requires Codex CLI with app-server dynamic tools (tested with 0.154.0). Sign in using ‘codex login’ in Terminal."
      )
      TextField("Codex executable (optional)", text: $path)
      Text(
        CodexTransport.installedExecutable()?.path
          ?? "Codex was not found in the usual installation locations."
      )
      .font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
      Link(
        "Codex installation and sign-in",
        destination: URL(string: "https://developers.openai.com/codex/cli")!)
      Text(
        "Choose a model in the chat, or use Codex default to follow your Codex configuration. The provider still comes from Codex. Changing models starts a new conversation and keeps visible chat history. Conversations are ephemeral; provider data policies still apply. Stop before changing the executable."
      )
      .font(.caption).foregroundStyle(.secondary)
      Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
    }.padding(24).frame(width: 520)
  }
}

// Observe the actual native window close event because SwiftUI scene disappearance may be delayed.
private struct AgentWindowObserver: NSViewRepresentable {
  let onClose: () -> Void
  func makeNSView(context: Context) -> ObserverView { ObserverView(onClose: onClose) }
  func updateNSView(_ view: ObserverView, context: Context) {}
  final class ObserverView: NSView {
    let onClose: () -> Void
    var observer: NSObjectProtocol?
    init(onClose: @escaping () -> Void) {
      self.onClose = onClose
      super.init(frame: .zero)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }
    override func viewDidMoveToWindow() {
      if let observer { NotificationCenter.default.removeObserver(observer) }
      guard let window else { return }
      observer = NotificationCenter.default.addObserver(
        forName: NSWindow.willCloseNotification, object: window, queue: .main
      ) { [weak self] _ in self?.onClose() }
    }
    deinit { if let observer { NotificationCenter.default.removeObserver(observer) } }
  }
}

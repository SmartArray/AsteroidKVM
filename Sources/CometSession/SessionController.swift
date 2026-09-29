// Desktop-only composition; both apps use the same connection state machine.
import AppKit
import Combine
import CometAgent
import CometCore
import CometMedia
@_exported import CometSessionCore

@MainActor public final class SessionController: SessionCore {
  public let transcription = TranscriptionController()
  @Published public var agentClickPreview: AgentClickPreview?
  var automationLease: UUID?
  public lazy var mcpServer = DeviceMCPServer(session: self)
  public var onAgentInterruption: (() -> Void)?
  public var onAgentIdentityChanged: (() -> Void)?
  public override func interruptAutomation(manualInput: Bool = false) {
    mcpServer.stopAutomation(manualInput: manualInput)
    onAgentInterruption?()
  }
  public override func identityChanged() {
    mcpServer.revokeAccess()
    transcription.clear()
    onAgentIdentityChanged?()
  }
  public override func credentialsChanged() { mcpServer.revokeAccess() }
  public override func preferencesChanged() { mcpServer.configure() }
  public override func stopDesktopActivity(reason: String) { transcription.stop(reason: reason) }
  public func paste() {
    guard let text = NSPasteboard.general.string(forType: .string) else { return }
    submitText(text)
  }
}

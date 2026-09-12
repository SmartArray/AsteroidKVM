// Exercise the installed Codex model against the real KVM only with explicit hardware-task opt-in.
import CometAgent
import CometCore
import CometMedia
import CometSession
import CoreImage
import ImageIO
import UniformTypeIdentifiers
import XCTest

final class AgentHardwareE2ETests: XCTestCase {
  @MainActor func testCodexCreatesUnsavedApplePoemOnRemoteComputer() async throws {
    guard ProcessInfo.processInfo.environment["COMET_AGENT_HARDWARE_E2E"] == "1",
      let path = ProcessInfo.processInfo.environment["COMET_E2E_SESSION"]
    else {
      throw XCTSkip(
        "Set COMET_AGENT_HARDWARE_E2E=1 and COMET_E2E_SESSION with an unlocked remote desktop to authorize the scratch-document task."
      )
    }
    let credentials = try JSONValue.decode(
      Data(contentsOf: URL(fileURLWithPath: NSString(string: path).expandingTildeInPath)))
    let raw = credentials["host"].text
    let url = try XCTUnwrap(URL(string: raw.contains("://") ? raw : "https://" + raw))
    var profile = ConnectionProfile(
      name: "Agent hardware E2E", host: try XCTUnwrap(url.host),
      port: url.port ?? (url.scheme == "http" ? 80 : 443), scheme: url.scheme ?? "https",
      username: credentials["username"].text)
    profile.keymap = credentials["keymap"].string ?? "en-us"
    let session = SessionController(profile: profile, token: credentials["token"].string)
    let adapter = SessionAgentComputer(session: session)
    let agent = AgentController(computer: adapter)
    session.onAgentInterruption = { [weak agent] in agent?.pause() }
    defer { agent.stop() }
    do {
      // The test file's explicit insecure flag authorizes pinning only this observed device certificate.
      session.connect()
      let connectDeadline = Date().addingTimeInterval(40)
      while !adapter.available && Date() < connectDeadline {
        if session.pendingCertificate != nil && credentials["insecure"].bool == true {
          session.approveCertificate()
        }
        try await Task.sleep(for: .milliseconds(100))
      }
      guard adapter.available else {
        throw AgentError(session.message ?? "The hardware video did not become available.")
      }
      let marker = "COMET APPLES " + String(Int.random(in: 1000...9999))
      agent.send(
        "Create a NEW text document in Windows Notepad and write a short four-line poem about apples (under 250 characters). Add '\(marker)' on a final line so this test can verify the result. Leave this new scratch document unsaved, visible, and focused. Do not replace existing document contents or save, send, publish, or run shell commands. Use only Comet screen/input tools, and verify the text visually before reporting success. If the machine is locked, ask the user to unlock it and do not type into sign-in fields."
      )
      let taskDeadline = Date().addingTimeInterval(300)
      while agent.status.busy && Date() < taskDeadline {
        try await Task.sleep(for: .milliseconds(200))
      }
      guard agent.status == .idle else {
        throw AgentError("Hardware agent did not finish: \(agent.detail)")
      }
      XCTAssertGreaterThan(agent.actionCount, 0)

      // Recognition uses fresh native video independently of the model's claim that the task succeeded.
      let frame = try XCTUnwrap(session.mailbox.snapshot())
      let recognized = try await TextRecognition.recognize(
        frame: frame,
        crop: CGRect(origin: .zero, size: frame.size), languages: ["en-US", "de-DE"])
      XCTAssertTrue(
        recognized.contains(marker),
        "The final remote document must visibly contain the unique test marker. Agent: \(agent.messages.filter { $0.kind == .assistant }.map(\.text))"
      )
      XCTAssertTrue(recognized.lowercased().contains("apple"))
      XCTAssertFalse(session.agentOwnsInput)
      XCTAssertEqual(session.mediaConnectionsStarted, 1)
      guard recognized.contains(marker), recognized.lowercased().contains("apple"),
        agent.actionCount > 0
      else {
        throw AgentError("The new poem was not visible in the final remote screen.")
      }
      print(
        "AGENT_HARDWARE_VERIFIED actions=\(agent.actionCount) frames=\(session.mailbox.statistics().received) marker=\(marker)"
      )

      // Store only the explicit test artifact in the ignored results folder, never the credentials or chat protocol.
      let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent()
      let folder = root.appendingPathComponent("test-results")
      try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
      let destinationURL = folder.appendingPathComponent("agent-hardware-poem.png")
      let context = CIContext(options: [.cacheIntermediates: false])
      let image = CIImage(cvPixelBuffer: frame.buffer)
      if let cg = context.createCGImage(image, from: image.extent),
        let destination = CGImageDestinationCreateWithURL(
          destinationURL as CFURL, UTType.png.identifier as CFString, 1, nil)
      {
        CGImageDestinationAddImage(destination, cg, nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
      }
      agent.stop()
      await session.disconnect()
    } catch {
      agent.stop()
      await session.disconnect()
      throw error
    }
  }
}

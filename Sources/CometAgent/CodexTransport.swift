// Own one Codex subprocess and serialize newline-delimited JSON-RPC without blocking the UI thread.
import CometCore
import Darwin
import Foundation

@MainActor public final class CodexTransport: AgentTransport {
  public var onEvent: ((JSONValue) -> Void)?
  public var onClose: ((String) -> Void)?
  private let executable: URL
  private let arguments: [String]
  private let directory: URL
  private var process: Process?
  private var input: FileHandle?
  private var sequence = 0
  private var pending: [Int: CheckedContinuation<JSONValue, Error>] = [:]
  private var deadlines: [Int: Task<Void, Never>] = [:]
  private let writes = DispatchQueue(label: "app.asteroidkvm.codex.write")
  private var generation = UUID()
  private var queuedWriteBytes = 0

  // Resolve common GUI-app installation paths explicitly because Finder does not inherit a shell PATH.
  public static func installedExecutable() -> URL? {
    let custom = UserDefaults.standard.string(forKey: "agentCodexPath") ?? ""
    let paths = [
      custom, "/opt/homebrew/bin/codex", "/usr/local/bin/codex",
      NSHomeDirectory() + "/.local/bin/codex", "/Applications/Codex.app/Contents/Resources/codex",
    ]
    return paths.first { !$0.isEmpty && FileManager.default.isExecutableFile(atPath: $0) }.map(
      URL.init(fileURLWithPath:))
  }

  // Disable local execution and integrations in this process, leaving the user's Codex configuration untouched.
  public static let configuration: [String: JSONValue] = {
    var result: [String: JSONValue] = [
      "web_search": .string("disabled"), "project_doc_max_bytes": .number(0),
      "history.persistence": .string("none"), "model_reasoning_effort": .string("medium"),
    ]
    for feature in [
      "shell_tool", "unified_exec", "shell_snapshot", "apps", "plugins", "hooks", "memories",
      "multi_agent", "multi_agent_v2", "computer_use", "browser_use", "browser_use_external",
      "in_app_browser",
      "in_app_local_automation", "image_generation", "view_image", "code_mode",
      "skill_search", "skill_mcp_dependency_install", "request_permissions_tool", "goals",
    ] {
      result["features." + feature] = .bool(false)
    }
    result["features.skip_host_skill_discovery"] = .bool(true)
    return result
  }()

  // Test executables use the same pipes and framing as the installed CLI; no shell interpolates user input.
  public init(executable: URL, arguments: [String]? = nil, directory: URL? = nil) {
    self.executable = executable
    self.directory =
      directory
      ?? FileManager.default.temporaryDirectory.appendingPathComponent(
        "AsteroidKVM-Agent", isDirectory: true)
    self.arguments =
      arguments ?? ["app-server", "--listen", "stdio://"]
      + Self.configuration.sorted { $0.key < $1.key }.flatMap {
        ["-c", $0.key + "=" + String(decoding: (try? $0.value.data()) ?? Data(), as: UTF8.self)]
      }
  }

  // Read stdout on a dedicated queue; forwarding whole lines to the main queue preserves event ordering.
  public func start() throws {
    guard process == nil else { return }
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let child = Process()
    let stdin = Pipe()
    let stdout = Pipe()
    // A child exiting during a screenshot write must produce EPIPE, never a process-terminating SIGPIPE.
    guard fcntl(stdin.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1) != -1 else {
      throw AgentError("Could not configure a safe Codex input pipe.")
    }
    child.executableURL = executable
    child.arguments = arguments
    child.currentDirectoryURL = directory
    child.standardInput = stdin
    child.standardOutput = stdout
    child.standardError = FileHandle.nullDevice
    let ticket = UUID()
    generation = ticket
    child.terminationHandler = { [weak self] _ in
      DispatchQueue.main.async {
        self?.ended(
          ticket, "Codex exited. Check your Codex installation and sign-in, then try again.")
      }
    }
    try child.run()
    process = child
    input = stdin.fileHandleForWriting
    let reader = stdout.fileHandleForReading
    DispatchQueue(label: "app.asteroidkvm.codex.read").async { [weak self] in
      var buffer = Data()
      while true {
        let chunk = reader.availableData
        if chunk.isEmpty { break }
        buffer.append(chunk)
        if buffer.count > 1_048_576 { break }
        while let newline = buffer.firstIndex(of: 10) {
          let line = Data(buffer[..<newline])
          buffer.removeSubrange(...newline)
          // Admit one complete event at a time; kernel pipe backpressure bounds floods of small envelopes.
          let delivered = DispatchSemaphore(value: 0)
          DispatchQueue.main.async {
            self?.receive(line, ticket: ticket)
            delivered.signal()
          }
          delivered.wait()
        }
      }
      try? reader.close()
      DispatchQueue.main.async { self?.ended(ticket, "The Codex connection closed.") }
    }
  }

  // Associate every request with a bounded deadline so launch or protocol failures cannot hang the chat.
  public func request(_ method: String, _ params: JSONValue) async throws -> JSONValue {
    guard process?.isRunning == true else { throw AgentError("Codex is not running.") }
    sequence += 1
    let id = sequence
    return try await withCheckedThrowingContinuation { continuation in
      pending[id] = continuation
      deadlines[id] = Task { [weak self] in
        do { try await Task.sleep(for: .seconds(45)) } catch { return }
        guard let self else { return }
        deadlines.removeValue(forKey: id)
        pending.removeValue(forKey: id)?.resume(
          throwing: AgentError(
            "Codex timed out during \(method). Try Stop, then send your request again."))
      }
      do {
        try write(
          .object(["id": .number(Double(id)), "method": .string(method), "params": params]))
      } catch {
        deadlines.removeValue(forKey: id)?.cancel()
        pending.removeValue(forKey: id)?.resume(throwing: error)
      }
    }
  }

  // Send notifications and server-request replies through the same ordered pipe writer.
  public func notify(_ method: String, _ params: JSONValue) throws {
    try write(.object(["method": .string(method), "params": params]))
  }
  public func respond(id: JSONValue, result: JSONValue) throws {
    try write(.object(["id": id, "result": result]))
  }
  public func reject(id: JSONValue, message: String) throws {
    try write(
      .object(["id": id, "error": .object(["code": .number(-32601), "message": .string(message)])]))
  }

  // Large screenshot replies are written off the main actor so Pause remains responsive under backpressure.
  private func write(_ message: JSONValue) throws {
    guard let input, process?.isRunning == true else { throw AgentError("Codex is not running.") }
    var data = try message.data()
    data.append(10)
    // Screenshot writes have a separate byte budget so a subprocess that stops reading cannot retain an unbounded queue.
    guard data.count <= 8_388_608, queuedWriteBytes <= 8_388_608 - data.count else {
      ended(generation, "Codex stopped consuming data. Remote control has stopped.")
      throw AgentError("Codex stopped consuming data. Stop and start a new conversation.")
    }
    queuedWriteBytes += data.count
    let byteCount = data.count
    let ticket = generation
    writes.async { [weak self] in
      defer {
        DispatchQueue.main.async {
          guard let self, self.generation == ticket else { return }
          self.queuedWriteBytes -= byteCount
        }
      }
      do { try input.write(contentsOf: data) } catch {
        DispatchQueue.main.async { self?.ended(ticket, "Could not send data to Codex.") }
      }
    }
  }

  // Deliver responses before notifications; unsolicited requests remain visible to the capability gate.
  private func receive(_ data: Data, ticket: UUID) {
    guard ticket == generation, process != nil else { return }
    guard let value = try? JSONValue.decode(data) else {
      ended(ticket, "Codex returned invalid protocol data. Update Codex and try again.")
      return
    }
    if value["method"].string != nil {
      onEvent?(value)
      return
    }
    // JSON-RPC IDs must match exact positive request integers; fractional and overflowing responses fail closed.
    guard let id = value["id"].integer(in: 1...Int.max) else {
      ended(ticket, "Codex returned an invalid response ID.")
      return
    }
    guard let continuation = pending.removeValue(forKey: id) else { return }
    deadlines.removeValue(forKey: id)?.cancel()
    if value["error"] != .null {
      continuation.resume(
        throwing: AgentError(value["error"]["message"].string ?? "Codex request failed."))
    } else {
      continuation.resume(returning: value["result"])
    }
  }

  // Termination invalidates late events and resolves every waiter exactly once.
  private func ended(_ ticket: UUID, _ reason: String) {
    guard ticket == generation, process != nil else { return }
    close()
    onClose?(reason)
  }
  public func close() {
    generation = UUID()
    let child = process
    process = nil
    let closingInput = input
    input = nil
    queuedWriteBytes = 0
    if child?.isRunning == true { child?.terminate() }
    // Closing shares the serial writer queue so a blocked write cannot make Stop block the main actor.
    writes.async { try? closingInput?.close() }
    deadlines.values.forEach { $0.cancel() }
    deadlines.removeAll()
    let requests = pending.values
    pending.removeAll()
    requests.forEach { $0.resume(throwing: CancellationError()) }
  }
}

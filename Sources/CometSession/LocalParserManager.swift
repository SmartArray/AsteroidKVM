import Combine
import CometCore
import CryptoKit
import Darwin
import Foundation

struct LocalParserRelease: Codable, Sendable {
  let schemaVersion: Int
  let version: String
  let runtimeURL: URL
  let runtimeSHA256: String
  let runtimeBytes: Int64
  enum CodingKeys: String, CodingKey {
    case schemaVersion = "schema_version"
    case version
    case runtimeURL = "runtime_url"
    case runtimeSHA256 = "runtime_sha256"
    case runtimeBytes = "runtime_bytes"
  }
  func validate() throws {
    guard schemaVersion == 1, !version.isEmpty, version.count < 64,
      runtimeURL.scheme == "https", runtimeURL.host == "github.com",
      runtimeURL.path.hasPrefix("/astral-sh/python-build-standalone/releases/download/"),
      runtimeSHA256.count == 64, runtimeSHA256.allSatisfy({ $0.isHexDigit }),
      (1...200_000_000).contains(runtimeBytes)
    else { throw ParserInstallError("The app's parser release manifest is invalid.") }
  }
  func verify(_ data: Data) throws {
    guard data.count == runtimeBytes,
      SHA256.hash(data: data).map({ String(format: "%02x", $0) }).joined()
        == runtimeSHA256.lowercased()
    else {
      throw ParserInstallError("Python download failed checksum verification. Retry installation.")
    }
  }
}

struct ParserInstallError: LocalizedError {
  let message: String
  init(_ message: String) { self.message = message }
  var errorDescription: String? { message }
}

// Held through install or service ownership. Multiple app instances cannot mutate the same installation.
final class ParserInstallLock {
  private let fd: Int32
  init(root: URL) throws {
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    fd = Darwin.open(
      root.appendingPathComponent("manager.lock").path, O_CREAT | O_RDWR | O_CLOEXEC, 0o600)
    guard fd >= 0 else {
      throw ParserInstallError("Cannot create the local parser installation lock.")
    }
    guard flock(fd, LOCK_EX | LOCK_NB) == 0 else {
      close(fd)
      throw ParserInstallError("Another AsteroidKVM instance is using this parser installation.")
    }
  }
  deinit {
    flock(fd, LOCK_UN)
    close(fd)
  }
}

private final class RuntimeDownloadProgress: NSObject, URLSessionTaskDelegate,
  URLSessionDownloadDelegate, @unchecked Sendable
{
  let update: @Sendable (Double) -> Void
  let expectedBytes: Int64
  private var last = -1
  init(expectedBytes: Int64, update: @escaping @Sendable (Double) -> Void) {
    self.expectedBytes = expectedBytes
    self.update = update
  }
  func urlSession(
    _ session: URLSession, downloadTask: URLSessionDownloadTask,
    didFinishDownloadingTo location: URL
  ) {}
  func urlSession(
    _ session: URLSession, downloadTask: URLSessionDownloadTask,
    didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64
  ) {
    if totalBytesWritten > expectedBytes {
      downloadTask.cancel()
      return
    }
    guard totalBytesExpectedToWrite > 0 else { return }
    let percent = Int(100 * totalBytesWritten / totalBytesExpectedToWrite)
    if percent != last {
      last = percent
      update(Double(percent) / 100)
    }
  }
  func urlSession(
    _ session: URLSession, task: URLSessionTask,
    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
    completionHandler: @escaping (URLRequest?) -> Void
  ) {
    // GitHub release assets redirect to this HTTPS storage endpoint.
    let allowed = [
      "github.com", "release-assets.githubusercontent.com", "objects.githubusercontent.com",
    ]
    completionHandler(
      request.url?.scheme == "https" && allowed.contains(request.url?.host ?? "") ? request : nil)
  }
}

// Keep pipe draining off the main actor, and only accept bounded structured setup progress.
private final class SetupProgressReader: @unchecked Sendable {
  private let lock = NSLock()
  private var pending = Data()
  private var errors = Data()
  let update: @Sendable (String, Double) -> Void
  init(update: @escaping @Sendable (String, Double) -> Void) { self.update = update }
  func consumeErrors(_ data: Data) {
    lock.lock()
    defer { lock.unlock() }
    errors.append(data)
    if errors.count > 65_536 { errors = errors.suffix(65_536) }
  }
  var errorData: Data {
    lock.lock()
    defer { lock.unlock() }
    return errors
  }
  func consume(_ data: Data) {
    lock.lock()
    defer { lock.unlock() }
    pending.append(data)
    while let newline = pending.firstIndex(of: 10) {
      let line = pending.prefix(upTo: newline)
      pending.removeSubrange(...newline)
      guard line.count < 4096,
        let item = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
        let phase = item["phase"] as? String, phase.count <= 200,
        let progress = item["progress"] as? Double, progress.isFinite, (0...1).contains(progress)
      else { continue }
      update(phase, progress)
    }
    if pending.count > 8192 { pending.removeAll() }
  }
}

@MainActor public final class LocalParserManager: ObservableObject {
  public static let shared = LocalParserManager()
  @Published public private(set) var installedVersion: String?
  @Published public private(set) var busy = false
  @Published public private(set) var running = false
  @Published public private(set) var status = "Not installed"
  @Published public private(set) var progress: Double?
  @Published public private(set) var error: String?
  public let root: URL
  private let package: URL
  private var operation: Task<Void, Never>?
  private var child: Process?
  private var ownership: ParserInstallLock?
  private var monitor: Task<Void, Never>?
  private var currentSettings: PerceptionSettings?
  private let fm = FileManager.default
  static let packageFiles = [
    "server.py", "backend.py", "setup.py", "requirements.lock", "parser-runtime.json",
  ]

  public var supported: Bool {
    #if arch(arm64)
      return true
    #else
      return false
    #endif
  }
  public init(root: URL? = nil, package: URL? = nil) {
    self.root =
      root
      ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
      .appendingPathComponent("AsteroidKVM/OmniParser", isDirectory: true)
    self.package = package ?? Bundle.main.resourceURL ?? Bundle.main.bundleURL
    installedVersion = try? activeInstallation().version
    if let installedVersion { status = "Installed · \(installedVersion) · Stopped" }
  }

  struct Installation: Codable {
    let directory: String
    let version: String
  }
  func activeInstallation() throws -> Installation {
    let value = try JSONDecoder().decode(
      Installation.self, from: Data(contentsOf: root.appendingPathComponent("active.json")))
    guard value.directory.hasPrefix("runtime-"),
      UUID(uuidString: String(value.directory.dropFirst(8))) != nil
    else {
      throw ParserInstallError("Invalid parser installation record. Install or repair the parser.")
    }
    return value
  }
  var installationDirectory: URL {
    get throws {
      root.appendingPathComponent("versions").appendingPathComponent(
        try activeInstallation().directory)
    }
  }
  public func accessToken() throws -> String {
    try String(contentsOf: root.appendingPathComponent("service.token"), encoding: .utf8)
      .trimmingCharacters(in: .whitespacesAndNewlines)
  }
  func release() throws -> LocalParserRelease {
    let value = try JSONDecoder().decode(
      LocalParserRelease.self,
      from: Data(contentsOf: package.appendingPathComponent("parser-runtime.json")))
    try value.validate()
    for file in Self.packageFiles
    where !fm.fileExists(atPath: package.appendingPathComponent(file).path) {
      throw ParserInstallError(
        "This app is missing its parser installer resources. Download a complete AsteroidKVM app build."
      )
    }
    return value
  }
  private func perform(_ body: @escaping @MainActor () async throws -> Void) {
    guard !busy else { return }
    busy = true
    error = nil
    operation = Task {
      defer {
        busy = false
        progress = nil
        operation = nil
      }
      do { try await body() } catch is CancellationError { status = "Cancelled" } catch {
        if Task.isCancelled {
          status = "Cancelled"
        } else {
          self.error = error.localizedDescription
          status = "Operation failed"
        }
      }
    }
  }
  public func install(
    restartSettings: PerceptionSettings? = nil,
    onInstalled: @escaping @MainActor () throws -> Void = {}
  ) {
    perform {
      let resume = self.running ? self.currentSettings : nil
      await self.stopService()
      try await self.installPackage()
      try onInstalled()
      if let resume { try await self.startService(settings: restartSettings ?? resume) }
    }
  }
  public func start(
    settings: PerceptionSettings, onReady: @escaping @MainActor () async -> Void = {}
  ) {
    perform {
      try await self.startService(settings: settings)
      await onReady()
    }
  }
  public func cancel() { operation?.cancel() }
  public func stop() {
    if busy { cancel() } else { perform { await self.stopService() } }
  }
  public func shutdown() async {
    operation?.cancel()
    await operation?.value
    await stopService()
  }

  // A minimal environment prevents a user's Python/Pip configuration from changing this managed runtime.
  private func environment(directory: URL) -> [String: String] {
    var env = [
      "HOME": NSHomeDirectory(), "PATH": "/usr/bin:/bin", "LANG": "en_US.UTF-8",
      "TMPDIR": NSTemporaryDirectory(), "PYTHONNOUSERSITE": "1", "PYTHONUNBUFFERED": "1",
      "PIP_CONFIG_FILE": "/dev/null", "PIP_DISABLE_PIP_VERSION_CHECK": "1",
      "HF_HUB_DISABLE_TELEMETRY": "1",
      "HF_HOME": root.appendingPathComponent("download-cache").path,
    ]
    let certificates = directory.appendingPathComponent(
      "python/lib/python3.12/site-packages/certifi/cacert.pem")
    if fm.fileExists(atPath: certificates.path) { env["SSL_CERT_FILE"] = certificates.path }
    return env
  }
  private func stopProcess(_ process: Process) async {
    guard process.isRunning else { return }
    process.terminate()
    await Task.detached {
      for _ in 0..<50 {
        if !process.isRunning { return }
        try? await Task.sleep(for: .milliseconds(100))
      }
      if process.isRunning { kill(process.processIdentifier, SIGKILL) }
      while process.isRunning { try? await Task.sleep(for: .milliseconds(50)) }
    }.value
  }
  private func command(
    _ executable: URL, _ args: [String], directory: URL, modelProgress: Bool = false
  ) async throws {
    try Task.checkCancellation()
    let process = Process()
    process.executableURL = executable
    process.arguments = args
    process.currentDirectoryURL = directory
    process.environment = environment(directory: directory)
    let output = Pipe()
    let errors = Pipe()
    let reader = SetupProgressReader { [weak self] phase, amount in
      Task { @MainActor in
        guard modelProgress, let self, self.busy else { return }
        self.status = phase
        self.progress = amount
      }
    }
    output.fileHandleForReading.readabilityHandler = { handle in
      reader.consume(handle.availableData)
    }
    // Third-party output may contain local paths; never expose it in MCP or normal app logs.
    errors.fileHandleForReading.readabilityHandler = { handle in
      reader.consumeErrors(handle.availableData)
    }
    process.standardOutput = output
    process.standardError = errors
    defer {
      output.fileHandleForReading.readabilityHandler = nil
      errors.fileHandleForReading.readabilityHandler = nil
    }
    try process.run()
    while process.isRunning {
      if Task.isCancelled {
        await stopProcess(process)
        throw CancellationError()
      }
      try? await Task.sleep(for: .milliseconds(100))
    }
    try Task.checkCancellation()
    guard process.terminationStatus == 0 else {
      let log = root.appendingPathComponent("install-error.log")
      fm.createFile(
        atPath: log.path, contents: reader.errorData, attributes: [.posixPermissions: 0o600])
      throw ParserInstallError(
        "\(status) failed (exit \(process.terminationStatus)). Check your internet connection and free disk space, then retry. Details are in install-error.log in the installation folder. Your previous installation is preserved."
      )
    }
  }

  func installPackage() async throws {
    try Task.checkCancellation()
    guard supported else {
      throw ParserInstallError("The managed local parser requires an Apple Silicon Mac.")
    }
    let manifest = try release()
    let lock = try ParserInstallLock(root: root)
    defer { withExtendedLifetime(lock) {} }
    let available = try root.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
      .volumeAvailableCapacityForImportantUsage
    if let available, available < 8_000_000_000 {
      throw ParserInstallError("Installation needs at least 8 GB of free disk space.")
    }
    let versions = root.appendingPathComponent("versions", isDirectory: true)
    let previous = try? activeInstallation().directory
    let directory = versions.appendingPathComponent(
      "runtime-" + UUID().uuidString, isDirectory: true)
    try fm.createDirectory(at: directory, withIntermediateDirectories: true)
    var committed = false
    defer { if !committed { try? fm.removeItem(at: directory) } }
    status = "Downloading Python runtime"
    progress = 0
    let delegate = RuntimeDownloadProgress(expectedBytes: manifest.runtimeBytes) {
      [weak self] amount in
      Task { @MainActor in self?.progress = amount }
    }
    let configuration = URLSessionConfiguration.ephemeral
    configuration.timeoutIntervalForResource = 1800
    let session = URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
    defer { session.invalidateAndCancel() }
    let (temporary, response) = try await session.download(from: manifest.runtimeURL)
    guard (response as? HTTPURLResponse)?.statusCode == 200 else {
      throw ParserInstallError(
        "Python runtime download failed. Retry when the download service is available.")
    }
    let archive = directory.appendingPathComponent("runtime.tar.gz")
    try fm.moveItem(at: temporary, to: archive)
    status = "Verifying Python runtime"
    progress = nil
    try await Task.detached {
      try manifest.verify(Data(contentsOf: archive, options: .mappedIfSafe))
    }.value
    try Task.checkCancellation()
    status = "Unpacking Python runtime"
    try await command(
      URL(fileURLWithPath: "/usr/bin/tar"), ["-xzf", archive.path, "-C", directory.path],
      directory: directory)
    try fm.removeItem(at: archive)
    let service = directory.appendingPathComponent("service", isDirectory: true)
    try fm.createDirectory(at: service, withIntermediateDirectories: true)
    for file in Self.packageFiles {
      try fm.copyItem(
        at: package.appendingPathComponent(file), to: service.appendingPathComponent(file))
    }
    let python = directory.appendingPathComponent("python/bin/python3.12")
    status = "Downloading and installing verified dependencies"
    try await command(
      python,
      [
        "-m", "pip", "install", "--only-binary=:all:", "--require-hashes", "--no-input",
        "--no-cache-dir",
        "--index-url", "https://pypi.org/simple", "-r",
        service.appendingPathComponent("requirements.lock").path,
      ], directory: directory)
    status = "Downloading pinned models"
    progress = 0
    let models = directory.appendingPathComponent("models")
    try await command(
      python,
      [
        service.appendingPathComponent("setup.py").path, "--model-root", models.path,
        "--download-models",
      ], directory: directory, modelProgress: true)
    status = "Verifying installation"
    progress = nil
    try await verifyInstallation(directory: directory)
    try Task.checkCancellation()
    guard fm.fileExists(atPath: models.appendingPathComponent("manifest.json").path) else {
      throw ParserInstallError("Model setup did not complete. Retry installation.")
    }
    // A stable token survives updates; the app supplies it automatically to its managed service.
    let token = root.appendingPathComponent("service.token")
    if !fm.fileExists(atPath: token.path) {
      try fm.copyItem(at: models.appendingPathComponent("service.token"), to: token)
      try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: token.path)
    }
    let record = Installation(directory: directory.lastPathComponent, version: manifest.version)
    try JSONEncoder().encode(record).write(
      to: root.appendingPathComponent("active.json"), options: .atomic)
    committed = true
    pruneVersions(keeping: Set([record.directory, previous].compactMap { $0 }))
    installedVersion = manifest.version
    status = "Installed · \(manifest.version) · Ready to start"
  }

  // Load and warm up the actual models offline before an update can replace the active record.
  func verifyInstallation(directory: URL) async throws {
    try await command(
      directory.appendingPathComponent("python/bin/python3.12"),
      [
        "-c",
        "import sys; sys.path.insert(0, sys.argv[1]); from server import enforce_offline; enforce_offline(); from backend import OmniParserBackend; OmniParserBackend(sys.argv[2], 'auto')",
        directory.appendingPathComponent("service").path,
        directory.appendingPathComponent("models").path,
      ], directory: directory)
  }

  // Keep the active runtime and one previous version; ignore anything outside our owned namespace.
  func pruneVersions(keeping directories: Set<String>) {
    let versions = root.appendingPathComponent("versions", isDirectory: true)
    for url in (try? fm.contentsOfDirectory(at: versions, includingPropertiesForKeys: nil)) ?? [] {
      let name = url.lastPathComponent
      if name.hasPrefix("runtime-"), UUID(uuidString: String(name.dropFirst(8))) != nil,
        !directories.contains(name)
      {
        try? fm.removeItem(at: url)
      }
    }
  }

  func startService(settings: PerceptionSettings) async throws {
    guard child == nil else { return }
    _ = try settings.validatedURL(path: "health")
    let directory = try installationDirectory
    ownership = try ParserInstallLock(root: root)
    defer { if child == nil { ownership = nil } }
    let process = Process()
    process.executableURL = directory.appendingPathComponent("python/bin/python3.12")
    process.arguments = [
      directory.appendingPathComponent("service/server.py").path,
      "--model-root", directory.appendingPathComponent("models").path,
      "--token-file", root.appendingPathComponent("service.token").path,
      "--port", String(settings.port), "--device", settings.preferredDevice,
      "--parent-pid", String(ProcessInfo.processInfo.processIdentifier),
    ]
    process.environment = environment(directory: directory)
    process.currentDirectoryURL = directory
    let log = root.appendingPathComponent("service.log")
    fm.createFile(atPath: log.path, contents: nil, attributes: [.posixPermissions: 0o600])
    let output = try FileHandle(forWritingTo: log)
    process.standardOutput = output
    process.standardError = output
    defer { try? output.close() }
    do {
      try process.run()
      child = process
      running = true
      currentSettings = settings
      status = "Loading local parser models…"
      var probeSettings = settings
      probeSettings.requestTimeout = 2
      let client = OmniParserClient(settings: probeSettings, token: try accessToken())
      let deadline = Date().addingTimeInterval(180)
      while Date() < deadline {
        try Task.checkCancellation()
        guard process.isRunning else {
          throw ParserInstallError(
            "The local parser exited. Another service may already be using port \(settings.port). Stop that service or choose a different port."
          )
        }
        let health = try? await client.health()
        if health?.error != nil {
          throw ParserInstallError(
            "Local models failed to load. Try CPU mode or Update / Repair. Details are in service.log in the installation folder."
          )
        }
        if let health, health.modelsLoaded {
          status = "Ready · \(health.device.uppercased())"
          monitor = Task { [weak self] in
            while !Task.isCancelled, process.isRunning { try? await Task.sleep(for: .seconds(1)) }
            guard !Task.isCancelled, let self else { return }
            self.child = nil
            self.running = false
            self.ownership = nil
            self.status = "Service stopped unexpectedly. Click Start to reconnect."
          }
          return
        }
        try await Task.sleep(for: .seconds(1))
      }
      throw ParserInstallError(
        "Models did not become ready within three minutes. Try CPU mode or Update / Repair.")
    } catch {
      await stopProcess(process)
      child = nil
      running = false
      ownership = nil
      throw error
    }
  }
  func stopService() async {
    monitor?.cancel()
    monitor = nil
    if let child { await stopProcess(child) }
    child = nil
    running = false
    ownership = nil
    if installedVersion != nil { status = "Stopped" }
  }
}

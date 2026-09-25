// A bounded localhost HTTP transport. MCP uses one JSON response per POST; GET streaming is optional.
import Foundation
import Network

struct MCPHTTPRequest {
  let method: String
  let path: String
  let headers: [String: String]
  let body: Data

  static func parse(_ data: Data) throws -> MCPHTTPRequest? {
    guard data.count <= 1_100_000 else { throw MCPHTTPError.invalid }
    guard let end = data.range(of: Data("\r\n\r\n".utf8)) else {
      if data.count > 16_384 { throw MCPHTTPError.invalid }
      return nil
    }
    guard end.upperBound <= 16_384,
      let head = String(data: data[..<end.lowerBound], encoding: .utf8)
    else { throw MCPHTTPError.invalid }
    let lines = head.components(separatedBy: "\r\n")
    let request = lines[0].components(separatedBy: " ")
    guard request.count == 3, request[2] == "HTTP/1.1" else { throw MCPHTTPError.invalid }
    var headers: [String: String] = [:]
    for line in lines.dropFirst() {
      guard let colon = line.firstIndex(of: ":") else { throw MCPHTTPError.invalid }
      let key = line[..<colon].lowercased()
      guard !key.isEmpty, headers[key] == nil, !key.contains(where: { $0.isWhitespace }) else {
        throw MCPHTTPError.invalid
      }
      headers[key] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
    }
    guard headers["transfer-encoding"] == nil,
      let length = Int(headers["content-length"] ?? "0"), (0...1_048_576).contains(length)
    else { throw MCPHTTPError.invalid }
    let total = end.upperBound + length
    guard data.count >= total else { return nil }
    guard data.count == total else { throw MCPHTTPError.invalid }
    return MCPHTTPRequest(
      method: request[0], path: request[1], headers: headers,
      body: Data(data[end.upperBound..<total]))
  }
}
enum MCPHTTPError: Error { case invalid }
struct MCPHTTPResponse {
  var status = 200
  var headers: [String: String] = [:]
  var body = Data()
  func encoded() -> Data {
    let reasons = [
      200: "OK", 202: "Accepted", 400: "Bad Request", 401: "Unauthorized", 403: "Forbidden",
      404: "Not Found", 405: "Method Not Allowed", 406: "Not Acceptable",
      415: "Unsupported Media Type", 429: "Too Many Requests", 500: "Internal Server Error",
    ]
    var head =
      "HTTP/1.1 \(status) \(reasons[status] ?? "Error")\r\nContent-Length: \(body.count)\r\nConnection: close\r\nCache-Control: no-store\r\nContent-Type: application/json\r\n"
    for (key, value) in headers { head += "\(key): \(value)\r\n" }
    return Data((head + "\r\n").utf8) + body
  }
}

@MainActor final class MCPHTTPServer {
  private var listener: NWListener?
  private var connections: [UUID: NWConnection] = [:]
  private var handlers: [UUID: Task<Void, Never>] = [:]
  var onState: ((String) -> Void)?
  let handler: @MainActor (MCPHTTPRequest) async -> MCPHTTPResponse
  init(handler: @escaping @MainActor (MCPHTTPRequest) async -> MCPHTTPResponse) {
    self.handler = handler
  }

  func start(port: UInt16) throws {
    stop()
    let parameters = NWParameters.tcp
    parameters.requiredLocalEndpoint = .hostPort(
      host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!)
    let listener = try NWListener(using: parameters)
    self.listener = listener
    listener.stateUpdateHandler = { [weak self, weak listener] state in
      Task { @MainActor in
        guard let self, self.listener === listener else { return }
        switch state {
        case .ready: self.onState?("Listening")
        case .failed:
          self.onState?("Could not listen on this port. Choose another port.")
          self.stop()
        default: break
        }
      }
    }
    listener.newConnectionHandler = { [weak self] connection in
      Task { @MainActor in self?.accept(connection) }
    }
    listener.start(queue: .main)
  }
  func stop() {
    listener?.cancel()
    listener = nil
    handlers.values.forEach { $0.cancel() }
    handlers.removeAll()
    connections.values.forEach { $0.cancel() }
    connections.removeAll()
  }
  private func accept(_ connection: NWConnection) {
    guard listener != nil, connections.count < 32 else {
      connection.cancel()
      return
    }
    let id = UUID()
    connections[id] = connection
    connection.start(queue: .main)
    receive(connection, id: id, buffer: Data())
    Task { [weak self, weak connection] in
      try? await Task.sleep(for: .seconds(10))
      guard let self, self.handlers[id] == nil, self.connections[id] != nil else { return }
      connection?.cancel()
      self.connections[id] = nil
    }
  }
  private func receive(_ connection: NWConnection, id: UUID, buffer: Data) {
    connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) {
      [weak self] data, _, complete, error in
      Task { @MainActor in
        guard let self, self.connections[id] != nil else { return }
        let accumulated = buffer + (data ?? Data())
        do {
          if let request = try MCPHTTPRequest.parse(accumulated) {
            self.handlers[id] = Task { [weak self] in
              guard let self else { return }
              let response = await self.handler(request)
              self.reply(response, to: connection, id: id)
            }
          } else if complete || error != nil {
            connection.cancel()
            self.connections[id] = nil
          } else {
            self.receive(connection, id: id, buffer: accumulated)
          }
        } catch { self.reply(MCPHTTPResponse(status: 400), to: connection, id: id) }
      }
    }
  }
  private func reply(_ response: MCPHTTPResponse, to connection: NWConnection, id: UUID) {
    handlers[id] = nil
    connection.send(
      content: response.encoded(),
      completion: .contentProcessed { [weak self] _ in
        connection.cancel()
        Task { @MainActor in self?.connections[id] = nil }
      })
  }
}

import CometCore
// Implement the uStreamer Janus exchange exposed by the inspected GLKVM firmware.
import Foundation
import WebRTC

@MainActor public final class JanusClient: NSObject {
  public let mailbox: FrameMailbox
  public var onError: ((Error) -> Void)?
  public var onConnected: (() -> Void)?
  public var onFeatures: ((JSONValue) -> Void)?
  private let api: CometAPI
  private var socket: URLSessionWebSocketTask?
  private var receiver: Task<Void, Never>?
  private var heartbeat: Task<Void, Never>?
  private var statsTask: Task<Void, Never>?
  private var factory: RTCPeerConnectionFactory?
  private var peer: RTCPeerConnection?
  private var videoTrack: RTCVideoTrack?
  private var audioTrack: RTCAudioTrack?
  private var microphoneTrack: RTCAudioTrack?
  private var sessionID: Double?, handleID: Double?
  private var pending: [String: String] = [:]
  private var candidates: [RTCIceCandidate] = []
  private var wantsMicrophone = false
  private var muted = false
  private var lastBytes = 0.0
  private var lastStats = Date()
  private var generation = UUID()
  private var iceServers: [RTCIceServer] = []
  public init(api: CometAPI, mailbox: FrameMailbox) {
    self.api = api
    self.mailbox = mailbox
    super.init()
  }

  // Fullscreen and resizing never call start; the media lifetime belongs to the session.
  public func start(microphone: Bool = false, muted: Bool = false) async throws {
    self.wantsMicrophone = microphone
    self.muted = muted
    socket = try await api.socket("/janus/ws", protocols: ["janus-protocol"])
    let generation = self.generation
    receiver = Task { [weak self] in
      guard let self else { return }
      do {
        while !Task.isCancelled, let socket, self.generation == generation {
          let message = try await socket.receive()
          let data: Data
          switch message {
          case .data(let d): data = d
          case .string(let s): data = Data(s.utf8)
          @unknown default: continue
          }
          try await receive(JSONValue.decode(data))
        }
      } catch { if !Task.isCancelled && self.generation == generation { onError?(error) } }
    }
    try await send("create")
  }

  // Correlate creation and attachment replies while allowing asynchronous Janus events and ICE.
  private func send(_ method: String, fields: [String: JSONValue] = [:]) async throws {
    let transaction = UUID().uuidString
    if ["create", "attach"].contains(method) { pending[transaction] = method }
    var data = fields
    data["janus"] = .string(method)
    data["transaction"] = .string(transaction)
    if let sessionID { data["session_id"] = .number(sessionID) }
    if let handleID, !["keepalive", "destroy"].contains(method) {
      data["handle_id"] = .number(handleID)
    }
    guard let socket else { throw URLError(.notConnectedToInternet) }
    try await socket.send(.string(String(decoding: JSONValue.object(data).data(), as: UTF8.self)))
  }

  // Wrap uStreamer requests with the current Janus session and handle identifiers.
  private func plugin(_ request: String, params: [String: JSONValue] = [:], jsep: JSONValue? = nil)
    async throws
  {
    var fields: [String: JSONValue] = [
      "body": .object(["request": .string(request), "params": .object(params)])
    ]
    if let jsep { fields["jsep"] = jsep }
    try await send("message", fields: fields)
  }

  // Advance Janus signaling from server messages while rejecting malformed negotiation state.
  private func receive(_ message: JSONValue) async throws {
    let kind = message["janus"].string ?? ""
    if kind == "error" {
      throw CometError.unsupported(
        "The Comet’s media service rejected the connection (\(message["error"]["code"].text)).")
    }
    if kind == "success", let transaction = message["transaction"].string,
      let operation = pending.removeValue(forKey: transaction)
    {
      if operation == "create" {
        sessionID = message["data"]["id"].number
        heartbeat = Task { [weak self] in
          while !Task.isCancelled {
            do {
              try await Task.sleep(for: .seconds(20))
              try await self?.send("keepalive")
            } catch { return }
          }
        }
        try await send(
          "attach",
          fields: [
            "plugin": .string("janus.plugin.ustreamer"), "opaque_id": .string(UUID().uuidString),
          ])
      } else {
        handleID = message["data"]["id"].number
        try await plugin("features")
        try await plugin(
          "watch",
          params: [
            "orientation": .number(0), "audio": .bool(true), "video": .bool(true),
            "mic": .bool(wantsMicrophone), "video_format": .number(0),
          ])
      }
    }
    if kind == "trickle", let sdp = message["candidate"]["candidate"].string {
      let c = RTCIceCandidate(
        sdp: sdp, sdpMLineIndex: Int32(message["candidate"]["sdpMLineIndex"].number ?? 0),
        sdpMid: message["candidate"]["sdpMid"].string)
      if peer?.remoteDescription != nil { try await peer?.add(c) } else { candidates.append(c) }
    }
    let result = message["plugindata"]["data"]
    if result["error"].string != nil {
      throw CometError.unsupported("The Comet could not start video: \(result["error"].text)")
    }
    if result["result"]["status"].string == "features" {
      let features = result["result"]["features"]
      onFeatures?(features)
      iceServers = features["ice"].array.compactMap { item in
        let urls = item["urls"].array.compactMap(\.string)
        let values = urls.isEmpty ? item["urls"].string.map { [$0] } ?? [] : urls
        return values.isEmpty
          ? nil
          : RTCIceServer(
            urlStrings: values, username: item["username"].string ?? "",
            credential: item["credential"].string ?? "")
      }
    }
    if let sdp = message["jsep"]["sdp"].string { try await answer(sdp) }
    if kind == "webrtcup" {
      onConnected?()
      startStatistics()
    }
    if ["hangup", "detached", "timeout"].contains(kind) { throw URLError(.networkConnectionLost) }
  }

  // Use WebRTC's native default decoder factory and asynchronous SDP APIs; no browser view is involved.
  private func answer(_ sdp: String) async throws {
    guard
      sdp.contains("H264/") || sdp.contains("VP8/") || sdp.contains("VP9/") || sdp.contains("AV1/")
    else {
      throw CometError.unsupported(
        "This stream offers no supported video codec. Select H.264 in Display. HEVC decoding is unavailable in this WebRTC build."
      )
    }
    let factory = RTCPeerConnectionFactory(
      encoderFactory: RTCDefaultVideoEncoderFactory(),
      decoderFactory: ReportingDecoderFactory(mailbox: mailbox))
    self.factory = factory
    let config = RTCConfiguration()
    config.sdpSemantics = .unifiedPlan
    config.iceServers = iceServers
    guard
      let peer = factory.peerConnection(
        with: config,
        constraints: RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil),
        delegate: self)
    else { throw CometError.invalidResponse }
    self.peer = peer
    if wantsMicrophone {
      let track = factory.audioTrack(withTrackId: "comet-microphone")
      microphoneTrack = track
      peer.add(track, streamIds: ["comet-microphone"])
    }
    try await peer.setRemoteDescription(RTCSessionDescription(type: .offer, sdp: sdp))
    for candidate in candidates { try await peer.add(candidate) }
    candidates.removeAll()
    let answer = try await peer.answer(
      for: RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil))
    try await peer.setLocalDescription(answer)
    try await plugin(
      "start", jsep: .object(["type": .string("answer"), "sdp": .string(answer.sdp)]))
  }

  // Playback muting only changes the local incoming track; microphone capture has a separate lifecycle.
  public func setMuted(_ muted: Bool) {
    self.muted = muted
    audioTrack?.isEnabled = !muted
  }

  // Cancel owned asynchronous work and release resources without affecting another session.
  public func stop() {
    generation = UUID()
    receiver?.cancel()
    heartbeat?.cancel()
    statsTask?.cancel()
    microphoneTrack?.isEnabled = false
    microphoneTrack = nil
    if let videoTrack { videoTrack.remove(mailbox) }
    videoTrack = nil
    audioTrack = nil
    peer?.close()
    peer = nil
    factory = nil
    socket?.cancel(with: .goingAway, reason: nil)
    socket = nil
    sessionID = nil
    handleID = nil
    pending.removeAll()
    candidates.removeAll()
    mailbox.clear()
  }

  // Sample low-frequency diagnostics without pushing individual frames through observable UI state.
  private func startStatistics() {
    guard statsTask == nil else { return }
    statsTask = Task { [weak self] in
      while !Task.isCancelled {
        do { try await Task.sleep(for: .seconds(1)) } catch { return }
        guard let self, let peer else { return }
        let report = await peer.statistics()
        var bytes = lastBytes
        var rtt = 0.0
        var decoder: String?
        for stat in report.statistics.values {
          if stat.type == "inbound-rtp",
            (stat.values["kind"] as? String ?? stat.values["mediaType"] as? String) == "video"
          {
            bytes = (stat.values["bytesReceived"] as? NSNumber)?.doubleValue ?? bytes
            decoder = stat.values["decoderImplementation"] as? String
          }
          if stat.type == "candidate-pair", (stat.values["state"] as? String) == "succeeded" {
            rtt = ((stat.values["currentRoundTripTime"] as? NSNumber)?.doubleValue ?? 0) * 1000
          }
        }
        let now = Date()
        let bitrate = max(0, bytes - lastBytes) * 8 / max(now.timeIntervalSince(lastStats), 0.001)
        mailbox.updateNetwork(bitrate: bitrate, rtt: rtt, decoder: decoder)
        lastBytes = bytes
        lastStats = now
      }
    }
  }
}

// Delegate callbacks hop to the owner actor only for signaling and track attachment, never for each frame.
extension JanusClient: RTCPeerConnectionDelegate {

  // Adapt native WebRTC delegate notifications to this connection’s signaling and media lifecycle.
  nonisolated public func peerConnection(
    _ peerConnection: RTCPeerConnection, didChange stateChanged: RTCSignalingState
  ) {}

  // Adapt native WebRTC delegate notifications to this connection’s signaling and media lifecycle.
  nonisolated public func peerConnection(
    _ peerConnection: RTCPeerConnection, didAdd stream: RTCMediaStream
  ) {}

  // Adapt native WebRTC delegate notifications to this connection’s signaling and media lifecycle.
  nonisolated public func peerConnection(
    _ peerConnection: RTCPeerConnection, didRemove stream: RTCMediaStream
  ) {}

  // The Janus offer drives negotiation; spontaneous renegotiation is intentionally left to the server.
  nonisolated public func peerConnectionShouldNegotiate(_ peerConnection: RTCPeerConnection) {}

  // Adapt native WebRTC delegate notifications to this connection’s signaling and media lifecycle.
  nonisolated public func peerConnection(
    _ peerConnection: RTCPeerConnection, didChange newState: RTCIceConnectionState
  ) {
    if newState == .failed {
      Task { @MainActor [weak self] in self?.onError?(URLError(.networkConnectionLost)) }
    }
  }

  // Adapt native WebRTC delegate notifications to this connection’s signaling and media lifecycle.
  nonisolated public func peerConnection(
    _ peerConnection: RTCPeerConnection, didChange newState: RTCIceGatheringState
  ) {}

  // Adapt native WebRTC delegate notifications to this connection’s signaling and media lifecycle.
  nonisolated public func peerConnection(
    _ peerConnection: RTCPeerConnection, didGenerate candidate: RTCIceCandidate
  ) {
    Task { @MainActor [weak self] in
      do {
        try await self?.send(
          "trickle",
          fields: [
            "candidate": .object([
              "candidate": .string(candidate.sdp), "sdpMid": .string(candidate.sdpMid ?? "0"),
              "sdpMLineIndex": .number(Double(candidate.sdpMLineIndex)),
            ])
          ])
      } catch { self?.onError?(error) }
    }
  }

  // Adapt native WebRTC delegate notifications to this connection’s signaling and media lifecycle.
  nonisolated public func peerConnection(
    _ peerConnection: RTCPeerConnection, didRemove candidates: [RTCIceCandidate]
  ) {}

  // Adapt native WebRTC delegate notifications to this connection’s signaling and media lifecycle.
  nonisolated public func peerConnection(
    _ peerConnection: RTCPeerConnection, didOpen dataChannel: RTCDataChannel
  ) {}

  // Adapt native WebRTC delegate notifications to this connection’s signaling and media lifecycle.
  nonisolated public func peerConnection(
    _ peerConnection: RTCPeerConnection, didAdd rtpReceiver: RTCRtpReceiver,
    streams: [RTCMediaStream]
  ) {
    Task { @MainActor [weak self] in
      guard let self, self.peer === peerConnection else { return }
      if let video = rtpReceiver.track as? RTCVideoTrack {
        videoTrack = video
        video.add(mailbox)
      }
      if let audio = rtpReceiver.track as? RTCAudioTrack {
        audioTrack = audio
        audio.isEnabled = !muted
      }
    }
  }
}

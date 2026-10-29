import CometCore
import Combine
// Implement the uStreamer Janus exchange exposed by the inspected GLKVM firmware.
import Foundation
@preconcurrency import WebRTC

@MainActor public final class JanusClient: NSObject {
  public let mailbox: FrameMailbox
  public var onError: ((Error) -> Void)?
  public var onConnected: (() -> Void)?
  public var onFeatures: ((JSONValue) -> Void)?
  public var onAudioLevel: ((Double) -> Void)?
  public var onAudioOutputMessage: ((String?) -> Void)?
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
  private var audioOutputDeviceUID: String?
  private var appliedOutputDeviceID: String?
  private var audioRouteGeneration = UUID()
  private var audioRouteTask: Task<Void, Never>?
  private let audioRouter = AudioOutputRouter()
  private var audioDevicesSubscription: AnyCancellable?
  private var audioMonitor = AudioActivityMonitor()
  private var lastBytes = 0.0
  private var lastStats = Date()
  private var generation = UUID()
  private var iceServers: [RTCIceServer] = []
  public init(api: CometAPI, mailbox: FrameMailbox) {
    self.api = api
    self.mailbox = mailbox
    super.init()
    let devices = AudioOutputDevices.shared
    audioDevicesSubscription = devices.$devices.combineLatest(devices.$defaultDeviceUID)
      .receive(on: DispatchQueue.main)
      .sink { [weak self] _ in self?.applyAudioOutput() }
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
      // ICE media indices must be representable and nonnegative before crossing the native WebRTC boundary.
      guard let index = message["candidate"]["sdpMLineIndex"].integer(in: 0...Int(Int32.max))
      else { throw CometError.invalidResponse }
      let c = RTCIceCandidate(
        sdp: sdp, sdpMLineIndex: Int32(index),
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
      audioDeviceModuleType: .audioEngine, bypassVoiceProcessing: true,
      encoderFactory: RTCDefaultVideoEncoderFactory(),
      decoderFactory: ReportingDecoderFactory(mailbox: mailbox), audioProcessingModule: nil)
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
    // Peer creation initializes the native device list. Select before SDP starts audio.
    appliedOutputDeviceID = nil
    applyAudioOutput()
    while let route = audioRouteTask { await route.value }
    guard self.factory === factory, !Task.isCancelled else { throw CancellationError() }
    // Routing failure is reported through onAudioOutputMessage. Continue negotiating
    // video so unavailable local playback does not disable access to the remote machine.
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

  // Keep incoming audio decoded for activity detection even when local playback is silent.
  public func setMuted(_ muted: Bool) {
    guard self.muted != muted else { return }
    self.muted = muted
    if let factory, let audioTrack {
      audioRouter.perform(factory: factory) { audioTrack.source.volume = muted ? 0 : 1 }
    }
  }

  public func setAudioOutputDevice(_ uid: String?) {
    audioOutputDeviceUID = uid
    applyAudioOutput()
  }

  // Each factory owns its output route. Never change the system-wide default device.
  private func applyAudioOutput() {
    guard let factory else { return }
    let devices = AudioOutputDevices.shared
    let selected = audioOutputDeviceUID.flatMap { uid in devices.devices.first { $0.id == uid } }
    let effectiveID = selected?.id ?? "default:\(devices.defaultDeviceUID ?? "")"
    let unavailable = audioOutputDeviceUID != nil && selected == nil
    // Keep only the latest desired selection while the current operation finishes.
    // Cancelling a Swift task cannot cancel a synchronous Core Audio driver call.
    guard audioRouteTask == nil else { return }
    audioRouteGeneration = UUID()
    guard effectiveID != appliedOutputDeviceID else {
      onAudioOutputMessage?(unavailable ? "Saved output unavailable · using System Default" : nil)
      return
    }
    let ticket = audioRouteGeneration
    onAudioOutputMessage?("Switching audio output…")
    audioRouteTask = Task { [weak self, audioRouter] in
      guard !Task.isCancelled else { return }
      let result = await audioRouter.select(selected?.id, factory: factory)
      guard let self, ticket == audioRouteGeneration, self.factory === factory, !Task.isCancelled else { return }
      audioRouteTask = nil
      if result == .success {
        appliedOutputDeviceID = effectiveID
        let unavailable = audioOutputDeviceUID.map { uid in
          !AudioOutputDevices.shared.devices.contains { $0.id == uid }
        } ?? false
        onAudioOutputMessage?(unavailable ? "Saved output unavailable · using System Default" : nil)
      } else {
        appliedOutputDeviceID = nil
        switch result {
        case .timedOut, .busy:
          onAudioOutputMessage?("Audio output did not respond. Wait a moment, then try again or reconnect.")
        case .failed:
          onAudioOutputMessage?("Could not switch audio output. Try another device.")
        case .cancelled, .success: break
        }
      }
      // A later selection wins, without queueing every intermediate picker value.
      let currentDevices = AudioOutputDevices.shared
      let currentUID = audioOutputDeviceUID.flatMap { uid in currentDevices.devices.first { $0.id == uid }?.id }
      let currentID = currentUID ?? "default:\(currentDevices.defaultDeviceUID ?? "")"
      if currentID != effectiveID { applyAudioOutput() }
    }
  }

  public func setAudioRecordingSink(_ sink: AudioRecordingSink?) {
    audioMonitor.setRecordingSink(sink)
  }

  // Cancel owned asynchronous work and release resources without affecting another session.
  public func stop() {
    audioMonitor.setRecordingSink(nil)
    generation = UUID()
    receiver?.cancel()
    heartbeat?.cancel()
    statsTask?.cancel()
    statsTask = nil
    appliedOutputDeviceID = nil
    audioRouteGeneration = UUID()
    audioRouteTask?.cancel()
    audioRouteTask = nil
    lastBytes = 0
    lastStats = Date()
    audioRouter.close(peer: peer, factory: factory, audio: audioTrack,
      microphone: microphoneTrack, monitor: audioMonitor, video: videoTrack, mailbox: mailbox)
    microphoneTrack = nil
    videoTrack = nil
    audioTrack = nil
    audioMonitor = AudioActivityMonitor()
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
    let ticket = generation
    statsTask = Task { [weak self] in
      while !Task.isCancelled {
        do { try await Task.sleep(for: .seconds(1)) } catch { return }
        guard let self, let peer else { return }
        guard let factory else { return }
        let report: RTCStatisticsReport = await withCheckedContinuation { continuation in
          self.audioRouter.perform(factory: factory) {
            peer.statistics { continuation.resume(returning: $0) }
          }
        }
        guard !Task.isCancelled, ticket == generation, self.peer === peer else { return }
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
        onAudioLevel?(audioMonitor.takeLevel())
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
      Task { @MainActor [weak self] in
        guard let self, peer === peerConnection else { return }
        onError?(URLError(.networkConnectionLost))
      }
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
      guard let self, peer === peerConnection else { return }
      do {
        try await send(
          "trickle",
          fields: [
            "candidate": .object([
              "candidate": .string(candidate.sdp), "sdpMid": .string(candidate.sdpMid ?? "0"),
              "sdpMLineIndex": .number(Double(candidate.sdpMLineIndex)),
            ])
          ])
      } catch { if peer === peerConnection { onError?(error) } }
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
    let track = rtpReceiver.track
    Task { @MainActor [weak self] in
      guard let self, self.peer === peerConnection, let factory else { return }
      if let video = track as? RTCVideoTrack {
        videoTrack = video
        let mailbox = mailbox
        audioRouter.perform(factory: factory) { video.add(mailbox) }
      }
      if let audio = track as? RTCAudioTrack {
        let previous = audioTrack
        let monitor = audioMonitor
        let muted = muted
        _ = monitor.takeLevel()
        audioTrack = audio
        audioRouter.perform(factory: factory) {
          previous?.remove(monitor)
          audio.source.volume = muted ? 0 : 1
          audio.add(monitor)
        }
      }
    }
  }
}

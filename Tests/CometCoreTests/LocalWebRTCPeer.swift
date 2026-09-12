import CometCore
// Feed generated pixel buffers through a real native WebRTC sender to test the entire receive pipeline.
import Foundation
import WebRTC
import XCTest

@MainActor final class LocalWebRTCPeer: NSObject, RTCPeerConnectionDelegate {
  let factory = RTCPeerConnectionFactory(
    encoderFactory: RTCDefaultVideoEncoderFactory(), decoderFactory: RTCDefaultVideoDecoderFactory()
  )
  var peer: RTCPeerConnection!
  var source: RTCVideoSource!
  var capturer: RTCVideoCapturer!
  var track: RTCVideoTrack!
  var gathered = false

  // Prefer H.264 so the test observes the VideoToolbox decoder-to-Metal path used by Comet.
  func offer() async throws -> String {
    let configuration = RTCConfiguration()
    configuration.sdpSemantics = .unifiedPlan
    peer = factory.peerConnection(
      with: configuration,
      constraints: RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil),
      delegate: self)
    source = factory.videoSource()
    source.adaptOutputFormat(toWidth: 640, height: 360, fps: 30)
    capturer = RTCVideoCapturer(delegate: source)
    track = factory.videoTrack(with: source, trackId: "fixture-video")
    let transceiver = peer.addTransceiver(with: track)
    let codecs = factory.rtpSenderCapabilities(forKind: kRTCMediaStreamTrackKindVideo).codecs.filter
    { $0.name == "H264" }
    if !codecs.isEmpty {
      _ = try transceiver?.setCodecPreferences(codecs, error: ())
    }
    let offer = try await peer.offer(
      for: RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil))
    try await peer.setLocalDescription(offer)
    let deadline = Date().addingTimeInterval(8)
    while !gathered && Date() < deadline { try await Task.sleep(for: .milliseconds(20)) }
    return try XCTUnwrap(peer.localDescription?.sdp)
  }

  // Submit an opaque BGRA test pattern at a native capture timestamp without involving screenshots.
  func frame(_ number: Int) throws {
    var pixelBuffer: CVPixelBuffer?
    let attributes =
      [kCVPixelBufferMetalCompatibilityKey: true, kCVPixelBufferIOSurfacePropertiesKey: [:]]
      as CFDictionary
    guard
      CVPixelBufferCreate(
        kCFAllocatorDefault, 640, 360, kCVPixelFormatType_32BGRA, attributes, &pixelBuffer)
        == kCVReturnSuccess, let pixelBuffer
    else { throw CometError.invalidResponse }
    CVPixelBufferLockBaseAddress(pixelBuffer, [])
    let bytes = CVPixelBufferGetBaseAddress(pixelBuffer)!.assumingMemoryBound(to: UInt8.self)
    let stride = CVPixelBufferGetBytesPerRow(pixelBuffer)
    memset(bytes, Int32((number * 7) % 255), stride * 360)
    CVPixelBufferUnlockBaseAddress(pixelBuffer, [])
    let timestamp = Int64(ProcessInfo.processInfo.systemUptime * 1_000_000_000)
    source.capturer(
      capturer,
      didCapture: RTCVideoFrame(
        buffer: RTCCVPixelBuffer(pixelBuffer: pixelBuffer), rotation: ._0, timeStampNs: timestamp))
  }

  // Delegate callbacks only notify gathering completion; the test owns all negotiation state.
  nonisolated func peerConnection(
    _ peerConnection: RTCPeerConnection, didChange stateChanged: RTCSignalingState
  ) {}
  nonisolated func peerConnection(
    _ peerConnection: RTCPeerConnection, didAdd stream: RTCMediaStream
  ) {}
  nonisolated func peerConnection(
    _ peerConnection: RTCPeerConnection, didRemove stream: RTCMediaStream
  ) {}
  nonisolated func peerConnectionShouldNegotiate(_ peerConnection: RTCPeerConnection) {}
  nonisolated func peerConnection(
    _ peerConnection: RTCPeerConnection, didChange newState: RTCIceConnectionState
  ) {}
  nonisolated func peerConnection(
    _ peerConnection: RTCPeerConnection, didChange newState: RTCIceGatheringState
  ) {
    if newState == .complete { Task { @MainActor [weak self] in self?.gathered = true } }
  }
  nonisolated func peerConnection(
    _ peerConnection: RTCPeerConnection, didGenerate candidate: RTCIceCandidate
  ) {}
  nonisolated func peerConnection(
    _ peerConnection: RTCPeerConnection, didRemove candidates: [RTCIceCandidate]
  ) {}
  nonisolated func peerConnection(
    _ peerConnection: RTCPeerConnection, didOpen dataChannel: RTCDataChannel
  ) {}
}
